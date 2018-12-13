//
//  SourceEditorCommand.swift
//  JSONExport-Xcode
//
//  Created by 霹雳火 on 2018/12/13.
//  Copyright © 2018 Ahmed Ali. All rights reserved.
//

import AppKit
import Foundation
import XcodeKit

// Commands correspond to definitions in Info.plist
enum Command: String {
    case pasteJSONAsCode = "PasteJSONAsCode"
}

// "io.quicktype.quicktype-xcode.X" -> Command(rawValue: "X")
func command(identifier: String) -> Command? {
    guard let component = identifier.split(separator: ".").last else {
        return nil
    }
    return Command(rawValue: String(component))
}


class SourceEditorCommand: NSObject, XCSourceEditorCommand {
    
    // Should hold list of supported languages, where the key is the language name and the value is LangModel instance
    var currentLang: LangModel!
    
    // Holds list of the generated files
    var files: [FileRepresenter] = [FileRepresenter]()
    
    func error(_ message: String, details: String = "No details") -> NSError {
        return NSError(domain: "quicktype", code: 1, userInfo: [
            NSLocalizedDescriptionKey: NSLocalizedString(message, comment: ""),
            NSLocalizedFailureReasonErrorKey: NSLocalizedString(details, comment: "")
        ])
    }
    
    // MARK: - Handling pre defined languages
    func loadSupportedLanguages() {
        if let langFile = Bundle.main.url(forResource: "Swift-Mappable", withExtension: "json") {
            if let data = try? Data(contentsOf: langFile),
                let langDictionary = (try? JSONSerialization.jsonObject(with: data, options: [])) as? NSDictionary {
                let lang = LangModel(fromDictionary: langDictionary)
                currentLang = lang
            }
        }
    }
    
    /**
     Creates and returns an instance of FilesContentBuilder. It also configure the values from the UI components to the instance. I.e includeConstructors
     
     - returns: instance of configured FilesContentBuilder
     */
    func prepareAndGetFilesBuilder() -> FilesContentBuilder {
        let filesBuilder = FilesContentBuilder.instance
        filesBuilder.includeConstructors = true
        filesBuilder.includeUtilities = true
//        filesBuilder.firstLine = firstLineField.stringValue
        filesBuilder.lang = currentLang
//        filesBuilder.classPrefix = ""
//        filesBuilder.parentClassName = ""
        return filesBuilder
    }
    
    func getFirstSelection(_ buffer: XCSourceTextBuffer) -> XCSourceTextRange? {
        for range in buffer.selections {
            guard let range = range as? XCSourceTextRange else {
                continue
            }
            return range
        }
        return nil
    }
    
    func isBlank(_ line: String) -> Bool {
        return line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    
    func isComment(_ line: String) -> Bool {
        return line.starts(with: "//")
    }
    
    func isImport(_ line: String) -> Bool {
        // TODO: we should split this functionality by current source language
        return ["import ", "#include ", "#import "].index { line.starts(with: $0) } != nil
    }
    
    func trimStart(_ lines: [String]) -> [String] {
        // Remove leading imports, comments, whitespace from start and end
        return Array(lines.drop(while: { line in
            isComment(line) || isBlank(line) || isImport(line)
        }))
    }
    
    func trimEnd(_ lines: [String]) -> [String] {
        return Array(lines
            .reversed()
            .drop { isBlank($0) || isComment($0) }
            .reversed()
        )
    }
    
    func insertingAfterCode(_ buffer: XCSourceTextBuffer, _ selection: XCSourceTextRange) -> Bool {
        for i in 0..<selection.start.line {
            let line = buffer.lines[i] as! String
            if isBlank(line) || isComment(line) {
                continue
            }
            return true
        }
        return false
    }
    
    func handleSuccess(lines: [String], _ invocation: XCSourceEditorCommandInvocation, _ completionHandler: @escaping (Error?) -> Void) {
        let buffer = invocation.buffer
        let selection = getFirstSelection(invocation.buffer) ?? XCSourceTextRange()
        
        // If we're pasting in the middle of anything, we omit imports
        let cleanLines = insertingAfterCode(buffer, selection)
            ? trimEnd(trimStart(lines))
            : trimEnd(lines)
        
        let selectionEmpty =
            selection.start.line == selection.end.line &&
            selection.start.column == selection.end.column
        
        if !selectionEmpty {
            let selectedIndices = selection.end.line == buffer.lines.count
                ? selection.start.line...(selection.end.line - 1)
                : selection.start.line...selection.end.line
            
            buffer.lines.removeObjects(at: IndexSet(selectedIndices))
        }
        
        let insertedIndices = selection.start.line..<(selection.start.line + cleanLines.count)
        buffer.lines.insert(cleanLines, at: IndexSet(insertedIndices))
        
        // Clear any selections
        buffer.selections.removeAllObjects()
        let cursorPosition = XCSourceTextPosition(line: selection.start.line, column: 0)
        buffer.selections.add(XCSourceTextRange(start: cursorPosition, end: cursorPosition))
        
        completionHandler(nil)
    }
    
    func handleError(message: String, _ invocation: XCSourceEditorCommandInvocation, _ completionHandler: @escaping (Error?) -> Void) {
        // Sometimes an error ruins our Runtime, so let's reinitialize it
        print("quicktype encountered an error: \(message)")
        
        let displayMessage = message.contains("cannot parse input")
            ? "Clipboard does not contain valid JSON"
            : "quicktype encountered an internal error"
        
        completionHandler(error(displayMessage, details: message))
    }
    
    func perform(with invocation: XCSourceEditorCommandInvocation, completionHandler: @escaping (Error?) -> Void) {
        // Implement your command here, invoking the completion handler when done. Pass it nil on success, and an NSError on failure.
        
        guard let _ = command(identifier: invocation.commandIdentifier) else {
            completionHandler(error("Unrecognized command"))
            return
        }
        
        guard var json = NSPasteboard.general.string(forType: .string) else {
            completionHandler(error("Couldn't get JSON from clipboard"))
            return
        }
        
        var rootClassName = "RootClass"
        // Do the lengthy process in background, it takes time with more complicated JSONs
        runOnBackground {
            json = stringByRemovingControlCharacters(json)
            if let data = json.data(using: String.Encoding.utf8) {
                do {
                    let jsonData: Any = try JSONSerialization.jsonObject(with: data, options: [])
                    var json: NSDictionary!
                    if jsonData is NSDictionary {
                        // fine nothing to do
                        json = jsonData as? NSDictionary
                    } else {
                        json = unionDictionaryFromArrayElements(jsonData as! NSArray)
                    }
                    
                    runOnUiThread {
                        self.loadSupportedLanguages()
                        self.files.removeAll(keepingCapacity: false)
                        let fileGenerator = self.prepareAndGetFilesBuilder()
                        fileGenerator.addFileWithName(&rootClassName, jsonObject: json, files: &self.files)
                        fileGenerator.fixReferenceMismatches(inFiles: self.files)
                        self.files = Array(self.files.reversed())
                        var lines: [String] = []
                        for file in self.files {
                            lines.append(contentsOf: file.toString().components(separatedBy: "\n"))
                        }
                        self.handleSuccess(lines: lines, invocation, completionHandler)
                    }
                } catch let error as NSError {
                    runOnUiThread({ () -> Void in
                        completionHandler(error)
                    })
                    
                } catch {
                    completionHandler(self.error("It seems your JSON object is not valid!"))
                }
            }
        }
    }
}
