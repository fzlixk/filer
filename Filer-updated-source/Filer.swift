import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

struct FileItem: Identifiable, Hashable {
    let url: URL
    let name: String
    let isDir: Bool
    let isPackage: Bool
    let size: Int64
    let modified: Date
    let kind: String
    var id: URL { url }
}

enum Icons {
    static var cache: [String: NSImage] = [:]
    static func icon(for item: FileItem) -> NSImage {
        let key = item.isDir ? "•dir" : (item.isPackage ? item.url.path : item.url.pathExtension.lowercased())
        if let i = cache[key] { return i }
        let img = NSWorkspace.shared.icon(forFile: item.url.path)
        cache[key] = img
        return img
    }
}

final class Pane: ObservableObject {
    @Published var url: URL
    @Published var items: [FileItem] = []
    @Published var selection = Set<URL>()
    @Published var filter = ""
    @Published var error: String?
    @Published var back: [URL] = []
    @Published var fwd: [URL] = []
    @Published var sortOrder: [KeyPathComparator<FileItem>] = [KeyPathComparator(\FileItem.name)]
    var showHidden = false

    init(start: URL) {
        url = start
        reload()
    }

    var visibleItems: [FileItem] {
        var list = items
        if !filter.isEmpty { list = list.filter { $0.name.localizedCaseInsensitiveContains(filter) } }
        list.sort(using: sortOrder)
        return list.filter { $0.isDir } + list.filter { !$0.isDir }
    }

    func reload() {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey, .localizedTypeDescriptionKey]
        var opts: FileManager.DirectoryEnumerationOptions = []
        if !showHidden { opts.insert(.skipsHiddenFiles) }
        do {
            let urls = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: opts)
            items = urls.map { u in
                let v = try? u.resourceValues(forKeys: Set(keys))
                let pkg = v?.isPackage ?? false
                return FileItem(url: u, name: u.lastPathComponent,
                                isDir: (v?.isDirectory ?? false) && !pkg, isPackage: pkg,
                                size: Int64(v?.fileSize ?? 0),
                                modified: v?.contentModificationDate ?? .distantPast,
                                kind: v?.localizedTypeDescription ?? "")
            }
            error = nil
        } catch let e {
            items = []
            let ns = e as NSError
            if ns.domain == NSCocoaErrorDomain && ns.code == 257 {
                self.error = "macOS denied access to \(url.path). Check that this exact Filer app is enabled in System Settings > Privacy & Security > Full Disk Access, then quit and reopen it. Error: \(e.localizedDescription)"
            } else {
                self.error = e.localizedDescription
            }
        }
        selection = selection.intersection(Set(items.map(\.url)))
    }

    func go(_ target: URL, record: Bool = true) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir), isDir.boolValue else {
            error = "Not a folder: \(target.path)"
            return
        }
        if record { back.append(url); fwd.removeAll() }
        url = target.standardizedFileURL
        selection = []
        filter = ""
        reload()
    }
    func goBack() { guard let p = back.popLast() else { return }; fwd.append(url); go(p, record: false) }
    func goForward() { guard let n = fwd.popLast() else { return }; back.append(url); go(n, record: false) }
    func goUp() { go(url.deletingLastPathComponent()) }
    func goToText(_ text: String) {
        let e = (text.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        go(URL(fileURLWithPath: e))
    }
}

final class Term: ObservableObject {
    var onOutput: ((String) -> Void)?
    var onFinish: (() -> Void)?
    var onDone: (() -> Void)?
    var columns = 100

    @Published private(set) var running = false
    @Published private(set) var currentCommand = ""
    @Published private(set) var lastExitStatus: Int32?
    @Published private(set) var outputLineCount = 0
    @Published private(set) var latestOutput = ""
    @Published private(set) var outputCopied = false
    private var process: Process?
    private var inputHandle: FileHandle?
    private var runID = 0
    private var pendingOutput = ""
    private var outputFlushScheduled = false

    func run(_ command: String, in directory: URL, cd: @escaping (URL) -> Void) {
        let command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty, !running else { return }

        runID += 1
        let currentRun = runID
        currentCommand = command
        lastExitStatus = nil
        outputLineCount = 0
        latestOutput = ""
        outputCopied = false
        pendingOutput = ""
        outputFlushScheduled = false
        running = true

        if command == "cd" || command.hasPrefix("cd ") || command.hasPrefix("cd\t") {
            changeDirectory(command, from: directory, runID: currentRun, completion: cd)
            return
        }

        // /usr/bin/script creates a real pseudo-terminal for the child shell.
        // This gives commands a TTY and lets stdin, Ctrl+C and interactive prompts work.
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = ["-q", "/dev/null", "/bin/zsh", "-lic", command]
        process.currentDirectoryURL = directory

        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "dumb"
        environment["NO_COLOR"] = "1"
        environment["CLICOLOR"] = "0"
        environment["PAGER"] = "cat"
        environment["GIT_PAGER"] = "cat"
        environment["COLUMNS"] = String(max(40, columns))
        environment["LINES"] = "24"
        process.environment = environment
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        do {
            try process.run()
        } catch {
            running = false
            lastExitStatus = -1
            let message = "Could not start the terminal command: \(error.localizedDescription)\n"
            appendToLatestOutput(message)
            onOutput?(message)
            onDone?()
            onFinish?()
            return
        }

        // The child now owns its duplicated pipe ends; the app only keeps the
        // write end of stdin and the read end of combined stdout/stderr.
        try? inputPipe.fileHandleForReading.close()
        try? outputPipe.fileHandleForWriting.close()
        self.process = process
        self.inputHandle = inputPipe.fileHandleForWriting

        let reader = outputPipe.fileHandleForReading
        reader.readabilityHandler = { [weak self, weak process] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                process?.waitUntilExit()
                let status = process?.terminationStatus ?? 0
                DispatchQueue.main.async {
                    guard let self, self.runID == currentRun else { return }
                    self.flushPendingOutput(runID: currentRun)
                    self.finish(runID: currentRun, exitStatus: status)
                }
            } else {
                let text = String(decoding: data, as: UTF8.self)
                self?.queueOutput(text, runID: currentRun)
            }
        }
    }

    // Coalesce bursts of pipe output into short batches. This avoids forcing
    // AppKit to relayout the terminal view for every tiny PTY read.
    private func queueOutput(_ text: String, runID currentRun: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.runID == currentRun else { return }
            self.pendingOutput += text
            guard !self.outputFlushScheduled else { return }
            self.outputFlushScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
                guard let self, self.runID == currentRun else { return }
                self.flushPendingOutput(runID: currentRun)
            }
        }
    }

    private func flushPendingOutput(runID currentRun: Int) {
        guard runID == currentRun else { return }
        outputFlushScheduled = false
        guard !pendingOutput.isEmpty else { return }
        let output = pendingOutput
        pendingOutput.removeAll(keepingCapacity: true)
        outputLineCount += output.reduce(into: 0) { count, character in
            if character == "\n" { count += 1 }
        }
        appendToLatestOutput(output)
        onOutput?(output)
    }

    // Keep a bounded, clean copy of the most recent command's actual output.
    // This excludes the terminal's prompt and app-generated exit-status label.
    private func appendToLatestOutput(_ rawOutput: String) {
        var output = rawOutput.replacingOccurrences(of: "\r\n", with: "\n")
        output = output.replacingOccurrences(
            of: "\u{1B}\\[[0-?]*[ -/]*[@-~]",
            with: "",
            options: .regularExpression
        )
        output = output.replacingOccurrences(
            of: "\u{1B}\\][^\u{07}]*\u{07}",
            with: "",
            options: .regularExpression
        )
        output = output.replacingOccurrences(of: "\u{1B}\\\\", with: "", options: .regularExpression)
        output = output.replacingOccurrences(of: "\u{07}", with: "")
        latestOutput += output

        // Prevent a single very verbose command from consuming unlimited memory.
        if latestOutput.utf16.count > 500_000 {
            latestOutput = String(latestOutput.suffix(400_000))
        }
    }

    func copyLatestOutput() {
        guard !latestOutput.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        outputCopied = pasteboard.setString(latestOutput, forType: .string)
    }

    private func changeDirectory(
        _ command: String,
        from directory: URL,
        runID currentRun: Int,
        completion: @escaping (URL) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let resolver = Process()
            let pipe = Pipe()
            resolver.executableURL = URL(fileURLWithPath: "/bin/zsh")
            resolver.arguments = ["-fc", "\(command) && print -r -- $PWD"]
            resolver.currentDirectoryURL = directory
            resolver.standardOutput = pipe
            resolver.standardError = pipe

            do {
                try resolver.run()
                try? pipe.fileHandleForWriting.close()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                resolver.waitUntilExit()
                let result = String(decoding: data, as: UTF8.self)
                let path = result.split(whereSeparator: \.isNewline).last.map(String.init)

                DispatchQueue.main.async {
                    guard let self, self.runID == currentRun else { return }
                    if resolver.terminationStatus == 0,
                       let path,
                       !path.isEmpty {
                        completion(URL(fileURLWithPath: path).standardizedFileURL)
                    } else if !result.isEmpty {
                        let message = result.hasSuffix("\n") ? result : result + "\n"
                        self.appendToLatestOutput(message)
                        self.onOutput?(message)
                    } else {
                        let message = "cd: unable to change directory\n"
                        self.appendToLatestOutput(message)
                        self.onOutput?(message)
                    }
                    self.finish(runID: currentRun, exitStatus: resolver.terminationStatus)
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self, self.runID == currentRun else { return }
                    let message = "cd: \(error.localizedDescription)\n"
                    self.appendToLatestOutput(message)
                    self.onOutput?(message)
                    self.finish(runID: currentRun, exitStatus: 1)
                }
            }
        }
    }

    private func finish(runID finishedRun: Int, exitStatus: Int32) {
        guard runID == finishedRun, running else { return }
        flushPendingOutput(runID: finishedRun)
        running = false
        lastExitStatus = exitStatus
        process = nil
        try? inputHandle?.close()
        inputHandle = nil
        if exitStatus != 0 {
            onOutput?("[exit \(exitStatus)]\n")
        }
        onDone?()
        onFinish?()
    }

    func send(_ text: String) {
        guard running, let inputHandle else { return }
        do {
            try inputHandle.write(contentsOf: Data(text.utf8))
        } catch {
            // The command may have exited between the key event and this write.
        }
    }

    func interrupt() {
        guard running else { return }
        send("\u{03}") // Ctrl+C is interpreted by the pseudo-terminal's line discipline.
        if let process {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak process] in
                if process?.isRunning == true { process?.terminate() }
            }
        }
    }

    func stop() { interrupt() }
}

struct Prompt: Identifiable {
    let id = UUID()
    let title: String
    let text: String
    let action: (String) -> Void
}

final class Store: ObservableObject {
    let panes: [Pane]
    let term = Term()
    @Published var dual = true
    @Published var showTerminal = true
    @Published var showNotes = false
    @Published var notesText = ""
    @Published var notesSaveStatus = "Saved"
    @Published var active = 0
    @Published var status = ""
    @Published var prompt: Prompt?
    @Published var undoStack: [(label: String, undo: () throws -> Void)] = []
    private var notesSaveWorkItem: DispatchWorkItem?
    private var terminationObserver: NSObjectProtocol?
    @Published var showHidden = false {
        didSet { panes.forEach { $0.showHidden = showHidden; $0.reload() } }
    }
    private var bag: [AnyCancellable] = []

    // Tracks an internal drag so hover-navigation always changes the pane that
    // was not used to start the drag. The target set also keeps the drag alive
    // while the pointer moves between sidebar, folder rows and pane backgrounds.
    private var activeDragSourceIndex: Int?
    private var activeDragTargets = Set<String>()
    private var hoverNavigationWorkItem: DispatchWorkItem?
    private var dragCleanupWorkItem: DispatchWorkItem?
    private var scheduledHoverTargetID: String?

    var current: Pane { panes[active] }
    var other: Pane { panes[active == 0 ? 1 : 0] }

    init() {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let downloads = home.appendingPathComponent("Downloads")
        let second = FileManager.default.fileExists(atPath: downloads.path) ? downloads : home
        panes = [Pane(start: home), Pane(start: second)]
        bag = panes.map { p in p.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() } }
        term.onDone = { [weak self] in self?.reloadAll() }
        loadNotes()
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.saveNotesNow()
        }
    }

    deinit {
        notesSaveWorkItem?.cancel()
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
    }

    private var applicationSupportDirectory: URL {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
    }

    private var notesFileURL: URL {
        applicationSupportDirectory
            .appendingPathComponent("Filer", isDirectory: true)
            .appendingPathComponent("Notes.txt", isDirectory: false)
    }

    private var legacyNotesFileURL: URL {
        applicationSupportDirectory
            .appendingPathComponent("Filefinder", isDirectory: true)
            .appendingPathComponent("Notes.txt", isDirectory: false)
    }

    private func loadNotes() {
        let fileManager = FileManager.default
        let sourceURL = fileManager.fileExists(atPath: notesFileURL.path)
            ? notesFileURL
            : legacyNotesFileURL
        guard fileManager.fileExists(atPath: sourceURL.path) else { return }

        do {
            notesText = try String(contentsOf: sourceURL, encoding: .utf8)
            if sourceURL != notesFileURL {
                do {
                    try fileManager.createDirectory(
                        at: notesFileURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try notesText.write(to: notesFileURL, atomically: true, encoding: .utf8)
                } catch {
                    notesSaveStatus = "Notes loaded; migration failed: \(error.localizedDescription)"
                    return
                }
            }
            notesSaveStatus = "Saved"
        } catch {
            notesSaveStatus = "Couldn't load notes: \(error.localizedDescription)"
        }
    }

    func scheduleNotesSave() {
        notesSaveWorkItem?.cancel()
        notesSaveStatus = "Saving…"
        let work = DispatchWorkItem { [weak self] in
            self?.saveNotesNow()
        }
        notesSaveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func saveNotesNow() {
        notesSaveWorkItem?.cancel()
        notesSaveWorkItem = nil
        do {
            try FileManager.default.createDirectory(
                at: notesFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try notesText.write(to: notesFileURL, atomically: true, encoding: .utf8)
            notesSaveStatus = "Saved"
        } catch {
            notesSaveStatus = "Save failed: \(error.localizedDescription)"
        }
    }

    func reloadAll() { panes.forEach { $0.reload() } }

    func noun(_ n: Int) -> String { n == 1 ? "1 item" : "\(n) items" }

    // Distinguish Filer-originated drags from files supplied by other apps.
    // Drags started in either Filer pane always move the original item.
    // Files dragged in from other applications retain the conventional copy behaviour.
    static let internalFileDragType = "com.filer.app.internal-file-drag"

    func dragProvider(for url: URL, from pane: Pane) -> NSItemProvider {
        // TableRow.itemProvider is called when a row drag starts.
        dragCleanupWorkItem?.cancel()
        hoverNavigationWorkItem?.cancel()
        activeDragTargets.removeAll()
        scheduledHoverTargetID = nil
        activeDragSourceIndex = panes.firstIndex(where: { $0 === pane })

        let selectedURLs = pane.selection.contains(url) ? Array(pane.selection) : [url]
        let orderedPaths = selectedURLs.map(\.absoluteString).sorted()
        let payload = (try? JSONSerialization.data(withJSONObject: orderedPaths)) ?? Data(url.absoluteString.utf8)

        // Publish an explicit file-URL representation so Finder and other apps
        // recognise this as a real file drag. Keep the multi-selection payload
        // private to this app so internal drops can move all selected items.
        let provider = NSItemProvider(item: url as NSURL, typeIdentifier: UTType.fileURL.identifier)
        provider.suggestedName = url.lastPathComponent
        provider.registerDataRepresentation(
            forTypeIdentifier: Self.internalFileDragType,
            visibility: .ownProcess
        ) { completion in
            completion(payload, nil)
            return nil
        }
        return provider
    }

    // Called by sidebar rows, folder rows and pane backgrounds as their drop
    // hover state changes. A destination triggers spring-loading; nil merely
    // keeps the drag session alive while crossing an empty part of a pane.
    func updateDragHover(
        targetID: String,
        destination: URL?,
        isTargeted: Bool,
        sourcePaneIndex: Int? = nil
    ) {
        guard let sourceIndex = activeDragSourceIndex, dual else { return }
        // Spring-load folders in the pane the drag started from. Folders in
        // the destination pane remain direct drop targets and do not replace
        // the source pane's contents while the user is dragging.
        if let sourcePaneIndex, sourcePaneIndex != sourceIndex { return }

        if isTargeted {
            dragCleanupWorkItem?.cancel()
            activeDragTargets.insert(targetID)

            guard let destination else { return }
            hoverNavigationWorkItem?.cancel()
            scheduledHoverTargetID = targetID

            let work = DispatchWorkItem { [weak self] in
                guard let self,
                      self.activeDragSourceIndex == sourceIndex,
                      self.activeDragTargets.contains(targetID) else { return }

                let otherIndex = sourceIndex == 0 ? 1 : 0
                let target = destination.standardizedFileURL
                let otherPane = self.panes[otherIndex]
                guard otherPane.url.standardizedFileURL != target else { return }

                // Do not add every hover step to the Back history.
                otherPane.go(target, record: false)
                self.status = "Other pane: \(target.lastPathComponent)"
            }
            hoverNavigationWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.65, execute: work)
        } else {
            activeDragTargets.remove(targetID)

            if scheduledHoverTargetID == targetID {
                hoverNavigationWorkItem?.cancel()
                hoverNavigationWorkItem = nil
                scheduledHoverTargetID = nil
            }

            if activeDragTargets.isEmpty {
                let cleanup = DispatchWorkItem { [weak self] in
                    guard let self, self.activeDragTargets.isEmpty else { return }
                    self.activeDragSourceIndex = nil
                    self.scheduledHoverTargetID = nil
                    self.hoverNavigationWorkItem = nil
                }
                dragCleanupWorkItem?.cancel()
                dragCleanupWorkItem = cleanup
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: cleanup)
            }
        }
    }

    private func finishInternalDrag() {
        dragCleanupWorkItem?.cancel()
        hoverNavigationWorkItem?.cancel()
        activeDragSourceIndex = nil
        activeDragTargets.removeAll()
        scheduledHoverTargetID = nil
    }

    @discardableResult
    func receiveDrop(_ providers: [NSItemProvider], into destination: URL) -> Bool {
        let validProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(Self.internalFileDragType) ||
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) ||
            $0.hasItemConformingToTypeIdentifier(UTType.url.identifier)
        }
        guard !validProviders.isEmpty else { return false }

        // If the private multi-selection type is unavailable for any reason,
        // activeDragSourceIndex still tells us that this drag began in Filer.
        // Capture that state before finishInternalDrag clears it, so the fallback
        // file-URL path moves the source instead of silently copying it.
        let isInternalDrag = activeDragSourceIndex != nil
        if isTrashLocation(destination) {
            return trashDropped(providers)
        }
        finishInternalDrag()

        let target = destination.standardizedFileURL
        for provider in validProviders {
            if provider.hasItemConformingToTypeIdentifier(Self.internalFileDragType) {
                provider.loadDataRepresentation(forTypeIdentifier: Self.internalFileDragType) { [weak self] data, error in
                    guard let self else { return }
                    guard let data,
                          let paths = try? JSONSerialization.jsonObject(with: data) as? [String] else {
                        DispatchQueue.main.async {
                            self.status = error?.localizedDescription ?? "Couldn't read the dragged selection."
                        }
                        return
                    }
                    let urls = paths.compactMap(URL.init(string:)).filter(\.isFileURL)
                    DispatchQueue.main.async {
                        for url in urls { self.placeDroppedFile(url, into: target, move: true) }
                    }
                }
            } else {
                let type = provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
                    ? UTType.fileURL.identifier : UTType.url.identifier
                provider.loadItem(forTypeIdentifier: type, options: nil) { [weak self] item, error in
                    guard let self else { return }
                    guard let source = Self.fileURL(from: item) else {
                        DispatchQueue.main.async {
                            self.status = error?.localizedDescription ?? "Couldn't read the dropped file."
                        }
                        return
                    }
                    DispatchQueue.main.async {
                        self.placeDroppedFile(source, into: target, move: isInternalDrag)
                    }
                }
            }
        }
        return true
    }

    private func isTrashLocation(_ url: URL) -> Bool {
        let trashURL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".Trash")
            .standardizedFileURL
        return url.standardizedFileURL == trashURL
    }

    // Dropping on the Trash sidebar item (or into an already-open Trash pane)
    // must use FileManager.trashItem, not move the file into ~/.Trash manually.
    @discardableResult
    func trashDropped(_ providers: [NSItemProvider]) -> Bool {
        let validProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(Self.internalFileDragType) ||
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) ||
            $0.hasItemConformingToTypeIdentifier(UTType.url.identifier)
        }
        guard !validProviders.isEmpty else { return false }
        finishInternalDrag()

        let group = DispatchGroup()
        let lock = NSLock()
        var collected = Set<URL>()
        var firstError: String?

        func collect(_ urls: [URL], error: Error? = nil) {
            lock.lock()
            collected.formUnion(urls.filter(\.isFileURL).map(\.standardizedFileURL))
            if firstError == nil, let error { firstError = error.localizedDescription }
            lock.unlock()
            group.leave()
        }

        for provider in validProviders {
            group.enter()
            if provider.hasItemConformingToTypeIdentifier(Self.internalFileDragType) {
                provider.loadDataRepresentation(forTypeIdentifier: Self.internalFileDragType) { data, error in
                    guard let data,
                          let paths = try? JSONSerialization.jsonObject(with: data) as? [String] else {
                        collect([], error: error)
                        return
                    }
                    let urls = paths.compactMap(URL.init(string:)).filter(\.isFileURL)
                    collect(urls)
                }
            } else {
                let type = provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
                    ? UTType.fileURL.identifier : UTType.url.identifier
                provider.loadItem(forTypeIdentifier: type, options: nil) { item, error in
                    if let url = Self.fileURL(from: item) {
                        collect([url])
                    } else {
                        collect([], error: error)
                    }
                }
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            lock.lock()
            let urls = Array(collected)
            let errorMessage = firstError
            lock.unlock()
            if !urls.isEmpty {
                self.trashURLs(urls)
            } else {
                self.status = errorMessage ?? "Couldn't read the dropped file."
            }
        }
        return true
    }

    private func trashURLs(_ urls: [URL]) {
        let fm = FileManager.default
        var undos: [() throws -> Void] = []
        var moved = 0
        var skipped = 0
        var firstFailure: String?

        for url in Set(urls.map(\.standardizedFileURL)) {
            // Avoid trying to trash the Trash folder itself or items already in it.
            if isTrashLocation(url) || url.path.hasPrefix(
                URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".Trash").path + "/"
            ) {
                skipped += 1
                continue
            }
            guard fm.fileExists(atPath: url.path) else {
                skipped += 1
                continue
            }

            var result: NSURL?
            do {
                try fm.trashItem(at: url, resultingItemURL: &result)
                moved += 1
                if let result {
                    let trashedURL = result as URL
                    undos.append { try fm.moveItem(at: trashedURL, to: url) }
                }
            } catch {
                skipped += 1
                if firstFailure == nil { firstFailure = error.localizedDescription }
            }
        }

        if !undos.isEmpty {
            record("Moved \(noun(moved)) to Trash", undos)
        }
        if moved > 0 {
            status = "Moved \(noun(moved)) to Trash" + (skipped > 0 ? ", \(skipped) skipped" : "")
        } else if let firstFailure {
            status = "Couldn't move the dropped item to Trash: \(firstFailure)"
        } else if skipped > 0 {
            status = "Couldn't move the dropped item to Trash."
        }
        reloadAll()
    }

    private static func fileURL(from item: NSSecureCoding?) -> URL? {
        if let url = item as? URL, url.isFileURL { return url }
        if let url = item as? NSURL, url.isFileURL { return url as URL }
        if let string = item as? String {
            if let url = URL(string: string), url.isFileURL { return url }
            if string.hasPrefix("/") { return URL(fileURLWithPath: string) }
        }
        if let data = item as? Data, let string = String(data: data, encoding: .utf8) {
            let value = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = URL(string: value), url.isFileURL { return url }
            if value.hasPrefix("/") { return URL(fileURLWithPath: value) }
        }
        return nil
    }

    private func placeDroppedFile(_ rawSource: URL, into rawDestination: URL, move: Bool) {
        let fm = FileManager.default
        let source = rawSource.standardizedFileURL
        let destination = rawDestination.standardizedFileURL
        var isDirectory: ObjCBool = false

        guard source.isFileURL, fm.fileExists(atPath: source.path, isDirectory: &isDirectory) else {
            status = "The dropped file is no longer available."
            return
        }
        guard source.path != destination.path else { return }
        if isDirectory.boolValue && destination.path.hasPrefix(source.path + "/") {
            status = "A folder can't be dropped into itself."
            return
        }
        if source.deletingLastPathComponent().standardizedFileURL == destination {
            status = "That item is already in this folder."
            return
        }

        let target = unique(source.lastPathComponent, in: destination)
        do {
            if move {
                try fm.moveItem(at: source, to: target)
                record("Move \(source.lastPathComponent)", [{ try fm.moveItem(at: target, to: source) }])
                status = "Moved \(source.lastPathComponent)"
            } else {
                try fm.copyItem(at: source, to: target)
                record("Copy \(source.lastPathComponent)", [{ try fm.trashItem(at: target, resultingItemURL: nil) }])
                status = "Copied \(source.lastPathComponent)"
            }
        } catch {
            status = "Couldn't \(move ? "move" : "copy") \(source.lastPathComponent): \(error.localizedDescription)"
        }
        reloadAll()
    }

    func record(_ label: String, _ undos: [() throws -> Void]) {
        guard !undos.isEmpty else { return }
        undoStack.append((label: label, undo: { for u in undos.reversed() { try u() } }))
    }

    func undo() {
        guard let last = undoStack.popLast() else { return }
        do {
            try last.undo()
            status = "Undid: \(last.label)"
        } catch {
            status = "Couldn't undo: \(error.localizedDescription)"
        }
        reloadAll()
    }

    func unique(_ name: String, in dir: URL) -> URL {
        let fm = FileManager.default
        var dest = dir.appendingPathComponent(name)
        guard fm.fileExists(atPath: dest.path) else { return dest }
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        var n = 1
        while true {
            let suffix = n == 1 ? " copy" : " copy \(n)"
            dest = dir.appendingPathComponent(ext.isEmpty ? base + suffix : base + suffix + "." + ext)
            if !fm.fileExists(atPath: dest.path) { return dest }
            n += 1
        }
    }

    func transfer(move: Bool) {
        guard dual else { return }
        let src = current, dst = other
        guard !src.selection.isEmpty else { return }
        let fm = FileManager.default
        var undos: [() throws -> Void] = []
        var done = 0, skipped = 0
        for u in src.selection {
            let target = dst.url
            if target.path == u.path || target.path.hasPrefix(u.path + "/") { skipped += 1; continue }
            if move && u.deletingLastPathComponent().path == target.path { skipped += 1; continue }
            let dest = unique(u.lastPathComponent, in: target)
            do {
                if move {
                    try fm.moveItem(at: u, to: dest)
                    undos.append { try fm.moveItem(at: dest, to: u) }
                } else {
                    try fm.copyItem(at: u, to: dest)
                    undos.append { try fm.trashItem(at: dest, resultingItemURL: nil) }
                }
                done += 1
            } catch {
                skipped += 1
                status = error.localizedDescription
            }
        }
        let verb = move ? "Moved" : "Copied"
        record("\(verb) \(noun(done))", undos)
        if done > 0 { status = "\(verb) \(noun(done))" + (skipped > 0 ? ", \(skipped) skipped" : "") }
        reloadAll()
    }

    func trash() {
        trashURLs(Array(current.selection))
    }

    func promptNewFolder() {
        prompt = Prompt(title: "New folder in \(current.url.lastPathComponent)", text: "untitled folder") { [weak self] name in
            self?.makeFolder(name)
        }
    }

    func makeFolder(_ raw: String) {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/") else { return }
        let dest = current.url.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: dest.path) else { status = "\"\(name)\" already exists."; return }
        do {
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: false)
            record("New folder \(name)", [{ try FileManager.default.trashItem(at: dest, resultingItemURL: nil) }])
            status = "Created \(name)"
        } catch {
            status = error.localizedDescription
        }
        reloadAll()
    }

    func promptRename(_ u: URL) {
        prompt = Prompt(title: "Rename \"\(u.lastPathComponent)\"", text: u.lastPathComponent) { [weak self] new in
            self?.rename(u, to: new)
        }
    }

    func rename(_ u: URL, to raw: String) {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), name != u.lastPathComponent else { return }
        let dest = u.deletingLastPathComponent().appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: dest.path) else { status = "\"\(name)\" already exists."; return }
        do {
            try FileManager.default.moveItem(at: u, to: dest)
            record("Rename \(u.lastPathComponent)", [{ try FileManager.default.moveItem(at: dest, to: u) }])
            status = "Renamed to \(name)"
        } catch {
            status = error.localizedDescription
        }
        reloadAll()
    }
}

final class TextBox: ObservableObject {
    @Published var text: String
    init(_ t: String = "") { text = t }
}

// Use an ObservableObject for drop highlighting rather than @State. This keeps
// the installer compatible with Swift toolchains where SwiftUI's State macro
// plugin isn't available to command-line swiftc.
final class DropTargetState: ObservableObject {
    @Published var isTargeted = false
}

struct PromptSheet: View {
    let p: Prompt
    @Environment(\.dismiss) var dismiss
    @StateObject private var box: TextBox
    init(p: Prompt) {
        self.p = p
        _box = StateObject(wrappedValue: TextBox(p.text))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(p.title).font(.headline)
            TextField("", text: $box.text).frame(width: 320)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("OK") { p.action(box.text); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }
}

struct FileNameCell: View {
    @EnvironmentObject var store: Store
    let item: FileItem
    let paneIndex: Int
    @StateObject private var dropTarget = DropTargetState()

    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: Icons.icon(for: item)).resizable().frame(width: 16, height: 16)
            Text(item.name).lineLimit(1)
        }
        .contentShape(Rectangle())
        .onDrop(
            of: [UTType.fileURL.identifier, UTType.url.identifier, Store.internalFileDragType],
            isTargeted: $dropTarget.isTargeted
        ) { providers in
            guard item.isDir else { return false }
            return store.receiveDrop(providers, into: item.url)
        }
        .onChange(of: dropTarget.isTargeted) { targeted in
            guard item.isDir else { return }
            store.updateDragHover(
                targetID: "folder-\(paneIndex)-\(item.url.path)",
                destination: item.url,
                isTargeted: targeted,
                sourcePaneIndex: paneIndex
            )
        }
    }
}

struct PaneView: View {
    @EnvironmentObject var store: Store
    @ObservedObject var pane: Pane
    let index: Int
    @StateObject private var path = TextBox()
    @StateObject private var dropTarget = DropTargetState()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Circle().fill(store.active == index ? Color.accentColor : Color.clear).frame(width: 8, height: 8)
                TextField("Path", text: $path.text)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { store.active = index; pane.goToText(path.text) }
                TextField("Filter", text: $pane.filter)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 130)
            }
            .padding(6)

            if let e = pane.error {
                Text(e).font(.caption).foregroundStyle(.red).padding(.horizontal, 8).frame(maxWidth: .infinity, alignment: .leading)
            }

            Table(selection: $pane.selection, sortOrder: $pane.sortOrder) {
                TableColumn("Name", value: \.name) { item in
                    FileNameCell(item: item, paneIndex: index)
                }
                TableColumn("Size", value: \.size) { item in
                    Text(item.isDir ? "—" : ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                        .foregroundStyle(.secondary)
                }
                .width(80)
                TableColumn("Modified", value: \.modified) { item in
                    Text(item.modified, format: .dateTime.day().month().year().hour().minute())
                        .foregroundStyle(.secondary)
                }
                .width(min: 120, ideal: 150)
                TableColumn("Kind", value: \.kind) { item in
                    Text(item.kind).foregroundStyle(.secondary)
                }
            } rows: {
                ForEach(pane.visibleItems) { item in
                    TableRow(item)
                        .itemProvider { store.dragProvider(for: item.url, from: pane) }
                }
            }
            .contextMenu(forSelectionType: URL.self) { ids in
                if !ids.isEmpty {
                    Button("Open") { ids.forEach { NSWorkspace.shared.open($0) } }
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting(Array(ids)) }
                    Button("Copy Path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(ids.map(\.path).joined(separator: "\n"), forType: .string)
                    }
                    if ids.count == 1, let u = ids.first {
                        Button("Rename…") { store.promptRename(u) }
                    }
                    Divider()
                    Button("Copy to Other Pane") { store.transfer(move: false) }
                    Button("Move to Other Pane") { store.transfer(move: true) }
                    Divider()
                    Button("Move to Trash") { store.trash() }
                }
            } primaryAction: { ids in
                if ids.count == 1, let u = ids.first, pane.items.first(where: { $0.url == u })?.isDir == true {
                    pane.go(u)
                } else {
                    ids.forEach { NSWorkspace.shared.open($0) }
                }
            }
            .onDeleteCommand { store.active = index; store.trash() }
        }
        .background(dropTarget.isTargeted ? Color.accentColor.opacity(0.10) : Color.clear)
        .overlay {
            if dropTarget.isTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.accentColor.opacity(0.8), lineWidth: 2)
                    .padding(2)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(
            of: [UTType.fileURL.identifier, UTType.url.identifier, Store.internalFileDragType],
            isTargeted: $dropTarget.isTargeted
        ) { providers in
            store.receiveDrop(providers, into: pane.url)
        }
        .onChange(of: dropTarget.isTargeted) { targeted in
            store.updateDragHover(
                targetID: "pane-\(index)",
                destination: nil,
                isTargeted: targeted
            )
        }
        .onAppear { path.text = pane.url.path }
        .onChange(of: pane.url) { newValue in path.text = newValue.path }
        .onChange(of: pane.selection) { _ in store.active = index }
        .simultaneousGesture(TapGesture().onEnded { store.active = index })
    }
}

final class TermTextView: NSTextView {
    static let mono = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    static let foreground = NSColor(white: 0.92, alpha: 1)
    static let background = NSColor(white: 0.09, alpha: 1)
    static let promptColor = NSColor(calibratedRed: 0.42, green: 0.84, blue: 0.55, alpha: 1)

    var promptStart = 0
    var promptEnd = 0
    var running = false
    var history: [String] = []
    var historyIndex = 0
    var draft = ""
    var promptProvider: () -> String = { "% " }
    var onCommand: ((String) -> Void)?
    var onSend: ((String) -> Void)?
    var onInterrupt: (() -> Void)?

    private var plainAttributes: [NSAttributedString.Key: Any] {
        [.font: Self.mono, .foregroundColor: Self.foreground]
    }
    private var endLocation: Int { textStorage?.length ?? 0 }

    var terminalColumns: Int {
        let characterWidth = ("M" as NSString).size(withAttributes: [.font: Self.mono]).width
        return max(40, Int((bounds.width - 20) / max(characterWidth, 1)))
    }

    private func emit(_ string: String, color: NSColor = TermTextView.foreground) {
        textStorage?.append(NSAttributedString(string: string, attributes: [.font: Self.mono, .foregroundColor: color]))
    }

    private func moveCaretToEnd() {
        setSelectedRange(NSRange(location: endLocation, length: 0))
    }

    private func moveCaretToInputIfNeeded() {
        if selectedRange().location < promptEnd { moveCaretToEnd() }
    }

    func showPrompt() {
        if endLocation > 0, textStorage?.string.hasSuffix("\n") == false { emit("\n") }
        promptStart = endLocation
        emit(promptProvider(), color: Self.promptColor)
        promptEnd = endLocation
        typingAttributes = plainAttributes
        moveCaretToEnd()
        scrollRangeToVisible(NSRange(location: endLocation, length: 0))
    }

    func updatePrompt() {
        guard !running, let storage = textStorage,
              promptEnd >= promptStart, promptEnd <= storage.length else { return }
        let freshPrompt = promptProvider()
        let range = NSRange(location: promptStart, length: promptEnd - promptStart)
        guard (storage.attributedSubstring(from: range).string != freshPrompt) else { return }
        storage.replaceCharacters(
            in: range,
            with: NSAttributedString(string: freshPrompt, attributes: [.font: Self.mono, .foregroundColor: Self.promptColor])
        )
        promptEnd = promptStart + (freshPrompt as NSString).length
    }

    func clearScreen() {
        textStorage?.setAttributedString(NSAttributedString())
        promptStart = 0
        promptEnd = 0
        showPrompt()
    }

    func appendOutput(_ rawOutput: String) {
        guard let storage = textStorage else { return }
        var output = rawOutput.replacingOccurrences(of: "\r\n", with: "\n")
        // Strip ANSI CSI controls and OSC title/hyperlink sequences. This is a
        // command terminal, not a full-screen VT100 emulator.
        output = output.replacingOccurrences(
            of: "\u{1B}\\[[0-?]*[ -/]*[@-~]",
            with: "",
            options: .regularExpression
        )
        output = output.replacingOccurrences(
            of: "\u{1B}\\][^\u{07}]*\u{07}",
            with: "",
            options: .regularExpression
        )
        output = output.replacingOccurrences(of: "\u{1B}\\\\", with: "", options: .regularExpression)

        storage.beginEditing()
        var pending = ""
        for character in output {
            switch character {
            case "\u{08}", "\u{7F}":
                if !pending.isEmpty {
                    pending.removeLast()
                } else if storage.length > promptEnd {
                    storage.deleteCharacters(in: NSRange(location: storage.length - 1, length: 1))
                }
            case "\r":
                if !pending.isEmpty { emit(pending); pending = "" }
                let currentText = storage.string as NSString
                let newline = currentText.range(of: "\n", options: .backwards)
                let lineStart = max(promptEnd, newline.location == NSNotFound ? 0 : newline.location + 1)
                if lineStart < storage.length {
                    storage.deleteCharacters(in: NSRange(location: lineStart, length: storage.length - lineStart))
                }
            case "\u{07}":
                break
            default:
                pending.append(character)
            }
        }
        if !pending.isEmpty { emit(pending) }

        // Bound memory use during commands that produce large amounts of output.
        if storage.length > 120_000 {
            let excess = storage.length - 80_000
            let currentText = storage.string as NSString
            let newline = currentText.range(of: "\n", options: [], range: NSRange(location: excess, length: storage.length - excess))
            let trimCount = newline.location == NSNotFound ? excess : newline.location + 1
            storage.deleteCharacters(in: NSRange(location: 0, length: trimCount))
            promptStart = max(0, promptStart - trimCount)
            promptEnd = max(0, promptEnd - trimCount)
        }
        storage.endEditing()
        scrollRangeToVisible(NSRange(location: storage.length, length: 0))
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if running {
            if modifiers.contains(.command) {
                super.keyDown(with: event)
                return
            }
            if modifiers.contains(.control),
               let character = event.charactersIgnoringModifiers?.lowercased(),
               let scalar = character.unicodeScalars.first {
                if character == "c" {
                    onInterrupt?()
                } else if scalar.value >= 97 && scalar.value <= 122,
                          let controlScalar = UnicodeScalar(scalar.value - 96) {
                    onSend?(String(Character(controlScalar)))
                }
                return
            }
            switch event.keyCode {
            case 36, 76: onSend?("\r")                 // Return / keypad Enter
            case 48: onSend?("\t")                     // Tab
            case 51: onSend?("\u{7F}")                 // Backspace
            case 53: onSend?("\u{1B}")                 // Escape
            case 115: onSend?("\u{1B}[H")               // Home
            case 119: onSend?("\u{1B}[F")               // End
            case 123: onSend?("\u{1B}[D")               // Left
            case 124: onSend?("\u{1B}[C")               // Right
            case 125: onSend?("\u{1B}[B")               // Down
            case 126: onSend?("\u{1B}[A")               // Up
            case 117: onSend?("\u{1B}[3~")              // Forward delete
            default:
                if let characters = event.characters,
                   let first = characters.unicodeScalars.first,
                   first.value < 0xF700 || first.value > 0xF8FF {
                    onSend?(characters)
                }
            }
            return
        }

        if modifiers.contains(.control), let character = event.charactersIgnoringModifiers?.lowercased() {
            if character == "c" {
                moveCaretToEnd()
                emit("^C\n")
                showPrompt()
                return
            }
            if character == "l" { clearScreen(); return }
        }
        if !modifiers.contains(.command) { moveCaretToInputIfNeeded() }
        typingAttributes = plainAttributes
        super.keyDown(with: event)
    }

    override func insertNewline(_ sender: Any?) {
        guard !running, let storage = textStorage, promptEnd <= storage.length else { return }
        let commandLine = (storage.string as NSString).substring(from: promptEnd)
        moveCaretToEnd()
        emit("\n")
        promptEnd = endLocation
        let command = commandLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if !command.isEmpty, history.last != command { history.append(command) }
        historyIndex = history.count
        draft = ""
        if command.isEmpty {
            showPrompt()
        } else {
            running = true
            onCommand?(command)
        }
    }

    private func setInput(_ input: String) {
        guard let storage = textStorage else { return }
        storage.replaceCharacters(
            in: NSRange(location: promptEnd, length: endLocation - promptEnd),
            with: NSAttributedString(string: input, attributes: plainAttributes)
        )
        moveCaretToEnd()
    }

    override func moveUp(_ sender: Any?) {
        guard !running, historyIndex > 0, let storage = textStorage else { return }
        if historyIndex == history.count {
            draft = (storage.string as NSString).substring(from: promptEnd)
        }
        historyIndex -= 1
        setInput(history[historyIndex])
    }

    override func moveDown(_ sender: Any?) {
        guard !running, historyIndex < history.count else { return }
        historyIndex += 1
        setInput(historyIndex == history.count ? draft : history[historyIndex])
    }

    override func moveToBeginningOfLine(_ sender: Any?) {
        if running { return }
        setSelectedRange(NSRange(location: promptEnd, length: 0))
    }

    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        guard !running, affectedCharRange.location >= promptEnd,
              NSMaxRange(affectedCharRange) <= endLocation else { return false }
        return super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
    }

    override func paste(_ sender: Any?) {
        if running {
            if let string = NSPasteboard.general.string(forType: .string) { onSend?(string) }
            return
        }
        moveCaretToInputIfNeeded()
        super.paste(sender)
    }
}

final class TerminalCoordinator {
    let store: Store

    init(store: Store) { self.store = store }

    private func prompt() -> String {
        let user = NSUserName()
        let host = ProcessInfo.processInfo.hostName.components(separatedBy: ".").first ?? "Mac"
        let directory = store.current.url
        let path = directory.path == NSHomeDirectory()
            ? "~"
            : (directory.path == "/" ? "/" : directory.lastPathComponent)
        return "\(user)@\(host) \(path) % "
    }

    func attach(_ textView: TermTextView) {
        textView.promptProvider = { [weak self] in self?.prompt() ?? "% " }
        textView.onCommand = { [weak self, weak textView] command in
            guard let self, let textView else { return }
            if command == "clear" {
                textView.clearScreen()
                textView.running = false
                return
            }
            let activePane = self.store.current
            self.store.term.columns = textView.terminalColumns
            self.store.term.run(command, in: activePane.url) { url in
                activePane.go(url)
            }
        }
        textView.onSend = { [weak self] input in self?.store.term.send(input) }
        textView.onInterrupt = { [weak self] in self?.store.term.interrupt() }
        store.term.onOutput = { [weak textView] output in textView?.appendOutput(output) }
        store.term.onFinish = { [weak textView] in
            textView?.running = false
            textView?.showPrompt()
        }
        textView.showPrompt()
    }
}

struct TerminalView: NSViewRepresentable {
    let store: Store

    func makeCoordinator() -> TerminalCoordinator {
        TerminalCoordinator(store: store)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = TermTextView.background
        scrollView.appearance = NSAppearance(named: .darkAqua)

        let textView = TermTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 200))
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 500, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isRichText = false
        textView.allowsUndo = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.drawsBackground = true
        textView.backgroundColor = TermTextView.background
        textView.textColor = TermTextView.foreground
        textView.font = TermTextView.mono
        textView.insertionPointColor = TermTextView.foreground
        scrollView.documentView = textView

        context.coordinator.attach(textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        (scrollView.documentView as? TermTextView)?.updatePrompt()
    }
}

struct Place: Identifiable {
    let name: String
    let symbol: String
    let url: URL
    var id: URL { url }
}

struct PlaceGroup: Identifiable {
    let title: String
    let places: [Place]
    var id: String { title }
}

struct SidebarPlaceRow: View {
    @EnvironmentObject var store: Store
    let place: Place
    @StateObject private var dropTarget = DropTargetState()

    var body: some View {
        Button { store.current.go(place.url) } label: {
            Label(place.name, systemImage: place.symbol)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onDrop(
            of: [UTType.fileURL.identifier, UTType.url.identifier, Store.internalFileDragType],
            isTargeted: $dropTarget.isTargeted
        ) { providers in
            if place.name == "Trash" {
                return store.trashDropped(providers)
            }
            return store.receiveDrop(providers, into: place.url)
        }
        .onChange(of: dropTarget.isTargeted) { targeted in
            store.updateDragHover(
                targetID: "sidebar-\(place.url.path)",
                destination: place.name == "Trash" ? nil : place.url,
                isTargeted: targeted
            )
        }
    }
}

struct Sidebar: View {
    @EnvironmentObject var store: Store

    var groups: [PlaceGroup] {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        func place(_ name: String, _ symbol: String, _ path: String) -> Place? {
            fm.fileExists(atPath: path) ? Place(name: name, symbol: symbol, url: URL(fileURLWithPath: path)) : nil
        }
        let favorites = [
            place("Home", "house", home),
            place("Desktop", "menubar.dock.rectangle", home + "/Desktop"),
            place("Documents", "doc", home + "/Documents"),
            place("Downloads", "arrow.down.circle", home + "/Downloads"),
            place("Applications", "square.grid.2x2", "/Applications")
        ].compactMap { $0 }
        let media = [
            place("Pictures", "photo", home + "/Pictures"),
            place("Music", "music.note", home + "/Music"),
            place("Movies", "film", home + "/Movies")
        ].compactMap { $0 }
        let cloud = [
            place("iCloud Drive", "icloud", home + "/Library/Mobile Documents/com~apple~CloudDocs"),
            place("Cloud Storage", "cloud", home + "/Library/CloudStorage")
        ].compactMap { $0 }
        let system = [
            place("Utilities", "wrench.and.screwdriver", "/System/Applications/Utilities"),
            place("Library", "books.vertical", home + "/Library"),
            place("Trash", "trash", home + "/.Trash")
        ].compactMap { $0 }
        let urls = fm.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
        let volumes = urls.map { Place(name: fm.displayName(atPath: $0.path), symbol: "externaldrive", url: $0) }
        return [
            PlaceGroup(title: "Favorites", places: favorites),
            PlaceGroup(title: "Media", places: media),
            PlaceGroup(title: "Cloud", places: cloud),
            PlaceGroup(title: "System", places: system),
            PlaceGroup(title: "Locations", places: volumes)
        ].filter { !$0.places.isEmpty }
    }

    var body: some View {
        List {
            ForEach(groups) { group in
                Section(group.title) {
                    ForEach(group.places) { row($0) }
                }
            }
        }
        .listStyle(.sidebar)
    }

    func row(_ p: Place) -> some View {
        SidebarPlaceRow(place: p)
    }
}

struct TerminalPanel: View {
    let store: Store
    @ObservedObject var term: Term

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label("Terminal", systemImage: "terminal")
                Spacer(minLength: 8)
                if term.running {
                    Text(term.currentCommand)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 300, alignment: .trailing)
                        .foregroundStyle(.secondary)
                    ProgressView()
                        .progressViewStyle(.linear)
                        .frame(width: 100)
                        .accessibilityLabel("Command running")
                    Text(term.outputLineCount > 0 ? "Running · \(term.outputLineCount) lines" : "Running · waiting for output")
                        .fontWeight(.medium)
                        .lineLimit(1)
                } else if let status = term.lastExitStatus {
                    Text(status == 0 ? "Finished" : "Exit code \(status)")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Ready")
                        .foregroundStyle(.secondary)
                }

                Button {
                    term.copyLatestOutput()
                } label: {
                    Image(systemName: term.outputCopied ? "checkmark" : "doc.on.doc")
                        .frame(width: 24, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .disabled(term.latestOutput.isEmpty)
                .accessibilityLabel("Copy latest terminal output")
                .help("Copy output from the most recent terminal command")
            }
            .font(.caption)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(.bar)

            TerminalView(store: store)
                .frame(minHeight: 105)
        }
        .frame(minHeight: 130, idealHeight: 220)
    }
}

struct NotesPanel: View {
    @ObservedObject var store: Store

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label("Notes", systemImage: "note.text")
                Spacer()
                Text(store.notesSaveStatus)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .font(.caption)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(.bar)

            TextEditor(text: $store.notesText)
                .font(.system(size: 13))
                .padding(.horizontal, 5)
                .padding(.vertical, 4)
                .onChange(of: store.notesText) { _ in
                    store.scheduleNotesSave()
                }
        }
        .frame(minHeight: 85)
        .accessibilityLabel("Filer notes")
    }
}

struct ContentView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        NavigationSplitView {
            Sidebar().navigationSplitViewColumnWidth(min: 150, ideal: 180, max: 240)
        } detail: {
            VStack(spacing: 0) {
                VSplitView {
                    HSplitView {
                        PaneView(pane: store.panes[0], index: 0)
                        if store.dual { PaneView(pane: store.panes[1], index: 1) }
                    }
                    .frame(minHeight: 260)

                    if store.showTerminal && store.showNotes {
                        HSplitView {
                            TerminalPanel(store: store, term: store.term)
                                .frame(minWidth: 280, minHeight: 125, idealHeight: 145)
                            NotesPanel(store: store)
                                .frame(minWidth: 240, minHeight: 125)
                        }
                        .frame(minHeight: 215, idealHeight: 270)
                    } else if store.showTerminal {
                        TerminalPanel(store: store, term: store.term)
                    } else if store.showNotes {
                        NotesPanel(store: store)
                            .frame(minHeight: 130, idealHeight: 220)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // A normal sibling view reserves layout space. safeAreaInset
                // on VSplitView could visually overlap the terminal at the bottom.
                HStack {
                    Text(store.status).lineLimit(1)
                    Spacer()
                    Text("\(store.current.selection.count) selected")
                }
                .font(.caption)
                .padding(6)
                .frame(maxWidth: .infinity)
                .background(.bar)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { store.current.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(store.current.back.isEmpty).help("Back")
                Button { store.current.goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(store.current.fwd.isEmpty).help("Forward")
                Button { store.current.goUp() } label: { Image(systemName: "arrow.up") }
                    .help("Enclosing folder")
            }
            ToolbarItemGroup {
                Button { store.promptNewFolder() } label: { Label("New Folder", systemImage: "folder.badge.plus") }
                    .help("New folder")
                Button { store.transfer(move: false) } label: { Label("Copy", systemImage: "doc.on.doc") }
                    .disabled(!store.dual).help("Copy selection to the other pane")
                Button { store.transfer(move: true) } label: { Label("Move", systemImage: "arrow.right.square") }
                    .disabled(!store.dual).help("Move selection to the other pane")
                Button { store.trash() } label: { Label("Trash", systemImage: "trash") }
                    .help("Move selection to Trash")
                Button { store.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                    .disabled(store.undoStack.isEmpty).help("Undo last action")
                Toggle(isOn: $store.dual) { Label("Two Panes", systemImage: "rectangle.split.2x1") }
                    .help("Two panes")
                Toggle(isOn: $store.showHidden) { Label("Hidden Files", systemImage: "eye") }
                    .help("Show hidden files")
                Toggle(isOn: $store.showTerminal) { Label("Terminal", systemImage: "terminal") }
                    .help("Show or hide the terminal")
                Toggle(isOn: $store.showNotes) {
                    Label("Notes", systemImage: "note.text")
                }
                .toggleStyle(.button)
                .help(store.showNotes ? "Hide notes panel" : "Show notes panel")
            }
        }
        .sheet(item: $store.prompt) { PromptSheet(p: $0) }
    }
}

@main
struct FilerApp: App {
    @StateObject private var store = Store()
    var body: some Scene {
        WindowGroup("Filer") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 900, minHeight: 560)
        }
    }
}

