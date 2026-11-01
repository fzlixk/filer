#!/bin/bash
set -Eeuo pipefail

APP_NAME="Filer"
BUNDLE_ID="com.filer.app"
APP_EXECUTABLE="Filer"
APP_VERSION="1.0"
MIN_MACOS="13.0"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This builder must be run on macOS because it uses Apple's Swift, codesign and pkgbuild tools."
  exit 1
fi

for tool in swiftc codesign pkgbuild sips iconutil base64; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Required macOS tool not found: $tool"
    echo "Install Xcode Command Line Tools, then run this builder again."
    exit 1
  fi
done

DOWNLOADS="$HOME/Downloads"
mkdir -p "$DOWNLOADS"
OUT_PKG="$DOWNLOADS/Filer-${APP_VERSION}.pkg"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/filer-pkg.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

APP="$WORK/Filer.app"
PAYLOAD="$WORK/payload"
SCRIPTS="$WORK/pkg-scripts"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$PAYLOAD/Applications" "$SCRIPTS"

cat > "$WORK/Filer.swift" <<'SWIFT'
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

SWIFT

cat > "$WORK/icon.b64" <<'B64'
iVBORw0KGgoAAAANSUhEUgAAAgAAAAIACAYAAAD0eNT6AAEAAElEQVR42uz9e9Rva1YWBs65vm9f
zjn7nCqKUzeoCyBgFVqAgBewBSwsFA3GYYYCbbTVdLR7DExaWxONOuzRNkqbjtptMmLMrRnxEjQx
cSSYqIjRRIjx0mIVeEGgKECgKKAup07ts/f3raf/+P3W+z7PnPNdv+8UFOc7v3pngnX23t9l/dZ6
17w8c87nMZs2bdq0adOmTZs2bdq0adOmTZs2bdq0adOmTZs2bdq0adOmTZs2bdq0adOmTZs2bdq0
adOmTZs2bdq0adOmTZs2bdq0adOmTZs2bdq0adOmTZs2bdq0adOmTZs2bdq0adOmTZs2bdq0adOm
TZs2bdq0adOmTZs2bdq0adOmTZs2bdq0adOmTZs2bdq0adOmTZs2bdq0adOmTZs2bdq0adOmTZs2
bdq0adOmTZs2bdq0adOmTZs2bdq0adOmTZs2bdq0adOmTZs2bdq0adOmTZs2bdq0adOmTZs2bdq0
adOmTZs2bdq0adOmTZs2bdq0adOmTZs2bdq0adOmTZs2bdq0adOmTZs2bdq0adOmTZs2bdq0adOm
TZs2bdq0adOmTZs2bdq0adOmTZs2bdq0adOmTZs2bdq0adOmTZs2bdq0adOmTZs2bdq0adOmTZs2
bdq0adOmTZs2bdq0adOmTZs2bdq0adOmTZs2bdq0adOmTZs2bdq0adOmTZs2bdq0adOmTZs2bdq0
adOmTZs2bdq0adOmTZs2bdq0adOmTZs2bdq0adOmTZs2bdq0adOmTZs2bdq0adOmTZs2bdq0adOm
TZs2bdq0adOmTZs2bdq0adOmTZs2bdq0adOmTZs2bdq0adOmTZs2bdq0adOmTZs2bdq0adOmTZs2
bdq0adOmTZs2bdq0adOmTZs2bdq0adOmTZs2bdq0adOmTZs2bdq0adOmTZs2bdq0adOmTZs2bdq0
adOmTZs2bdq0adOmTZs2bdq0adOmTZs2bdq0adOmTZs2bdq0adOmTZs2bdq0adOmTZs2bdq0adOm
TZs2bdq0adOmTZs2bdq0adOmTZs2bdq0adOmTZs2bdq0adOmTZs2bdq0adOmTZs2bdq0adOmTZs2
bdq0adOmTZs2bdq0adOmTZs2bdq0adOmTZs2bdq0adOmTZs2bdq0adOmTZs2bdq0adOmTZs2bdq0
adOmTZs2bdq0adOmTZs2bdq0adOmTZs2bdq0adOmTZs2bdq0adOmTZs2bdq0adOmTZs2bdq0adOm
TZs2bdq0adOmTZs27RzM5y34yd0898MthMEAsy960yc8/bNf//QbP/d1T3/2K+9fPvuWZx980Sc8
eeeNT931Z1/91P23XF9jvVhsMTMDDj/Etz8cf5bh+P/48b/dDcDhj8Dxdx6/GYffvf0c4Hht25cc
r+1wvdvjPnwvjl/Mn8HlWEC/BmbmOP5Oa9ez/Tva5zj8ru3nbddU30O6Cdiu1NJ19G/ww9fJdYXv
83YZ7To3i59Zfnb7CTDAVndbPvL4+oMffOH6PT/+kavv++6feP5/e9ePPP93/uGPPPePv/Fd732P
u9ly/ASga5g2bdq0mQCcoV0u3gLw4+vu8h/cvfR/9Du++H+67/bMpS9P3b/AA/Pl4t6lP7m4X7ph
uVgu7lLopGC+BfYtSHG868GfA2AK7McEgn9OiKYUBW0Q/ELEbL+nB+T+O8PPDj8Kx+vxY2LUP+fa
rhktUUH/HdvXrcffs1BEj9dI11ceZu/JFPiP8bIp94qfH+brivVqhV09XvH8o+vrDz9el488d339
3p/5x//Olzy+Xtuvu3Phtq5m15ipwLRp02YCcDZ292Ixd7MXrrrD/6Wf8eyzf+SrPvs/fPhjDz/0
9P3L17/1Ta/8ZXa9mq04/J/BbOVSfBAYKOiAvsYl2Le0Yb9CFjBh+/4qRELiqCtkkAKonhqnANn/
+fDXHGr9VPl/TG68+qVDw4YcgL7SvSEpseo3PyYU29fQ78Lx/rREixOy+HndzJYjWnG52Hd8//u/
6fkX8L57r7z31G/7C9/5r/+t7/vA+83M7l0utq6wx+tMBKZNmzYTgJftzbl3uZiZ2cNj4P8Db/+M
L/mFb3n1V3zkQy8891mvfuqXfPrP+MQvsUfXZmZ2/aEXHvkR3ncsywbjux/+rgedtQU9hGCf/gyY
+2LSEjBNFnzRqrnFLJRlvwRa6TzIfyv0D4utB+SvyyV6b0lYbkUcWgQa/Ms2RExd0JGDDfNvgbw3
FSTV2XITbLG8d1CkBdNaLWYpGYDZajC7XrG6Y714cPeurTC7d2nv/K73/cUfXP07/+u/+y/+9H/y
D37on5qZ3b9cbAXs0fVMBKZNmzYTgJeFLW5252Kx6xV2dQyqf/RXvPVffubBvVd+zWe9+v/15Gtf
8ay9cGX2+NoeP/foeb/0ZYXZ3Qu/34IlVY5Ye5Vpxi3+HnS2ILr10b0onqVTr30Cc+rNb/8Wg+GG
JXhMRMIpaNezfQYgJA1bUtIh/R7H/fgt6P14Rj98a1mYzAhwT763DzjfgCYZyGhIak9YnGvgP/U2
isMN3mcavEA7sK4t2dryjqvr9eHxfq13nrjzpD1zz97z3T/xv/61H/zQn/yeH3nuu/7Q//yebzUz
u3ex2KPrdc4ITJs2bSYAt9ku3KWH+3/78s/8Ulthf+Ar3vo37MFdsx//sD16dP2c+7K4Y7lclvvU
gpeKMSYAHYIOw2lcYXNgcxOYuw3dHYOyx6EB7l1TQG6V8THzcOnx+zDAGlfZAXnYEoCeVlDiwRfu
Fqp9S9cMeK/o273Q41nNQVQDgy2poAtWjEETje05MRKQWwguCYCtPDRwuLbV8Oj6kT26+8TywF71
hF398HMPv+5v/8BX/NCHHr73P/r7P/ydF8sh0ZtdgWnTps0E4BZW/XcvFnt4tdqDO4t/zee/8We+
6u7FK7/+133et9m62qMfe/4hrq4fXVwuT14uy6VWoCGI8mQZJRNoAQgUhLZBP6pKqeUc4qgkGv3P
FDipot+up/XZJbjqz0sJgHwBoe36jzlIe9HDzzCEVub0b70nb7kZEKvzHdN2A+oJA9D9gn6n731S
5ARgu3dX17i6vr56/t6dy2fsE+7b+v6PXP2fv+m7P+dP/b1/8Z3b1sAcEpw2bdpMAG5N8Hdbj075
VU/c8d/+iz/97b/vV/6sb7ZHV/bwJz7yfjOzexfLM+62BDA8JwAnh9h0KLD1mnn1T2NvEbl6ZgAp
iouAFv4bWI+5ieuvrHr/VKmXQfGIILhkKtzSGN8Khf+NL/DYNuhNem6VuJ8YLCzDtu4ApJHI9GWa
tI1elIRq0HzEeo2rFwwfvHdneWZ5+v7lv/pffPun/pl/+CPvrlCmadOmTZsJwEtgmzP+pGfuXbzm
wf27v/5zP+kdv+NXv+0vfeDdP/H9T9xbPuHuxcWDHARDSUtVdtx9d/c+hb4Faivg/1EIAw6wM3aC
rHGsRtj3j1U26jDJkDwlBrKel743lvYuiYnkHnHv7viXWHX90a0uvzu0b2USENsk7oOkaxDZ4zCg
3Kti2eIwO2DH2QGvv/bw3NcXHq8fvP+6B6/86v/s//fmv/CP3vue9Yg4zXbAtGnTZgLwUn34o99+
+t6l/7GvfOtv+Ne+9DP+v/bcC/b40dXzdy6XJ7VyDlV2jAjhtuYgRAFdCH8qOBwp2HCs9RBoe7XN
pDry3WFVb69atnL6ECvnALFHH+CGxCWQ7xdGVXVYxTMJ+D5MltKAYxj+639XXEuBLKBAQfR+9EFN
58zOENCgw989/2h935Ove+rZf/U///ZP/cZ3vvfd6xH9mUDAtGnTZgLwklT/Zsuy2Df8ms/+2q/5
gjf+iauPPH5obpeXi1/GwbyDg19TIJHK9KO8Du5tM0itU/zFPD8GD9HHgbdKUEb77/oT+gSDSZXt
RVldluVWl9PxM+kA5agFMUwgJEGo7pdet2w83Og5QhAXZ/KlDtAo2dLxDH348dWPP/XqB6/6LX/m
nW/9T//BD/2Ti2UxJhKaNm3atJ/WGPjx+sEvl8WuAfurv/nn/rtf+dmf9H/H48fXF8ty1zfuOacK
kCrQVoG79ZU295wEEJSc6HSNhvG2MvD4s5zDLKhlsEH/scVQ1uA8DFhA/uCP1QNiSwTcU2Lhodvd
BhePvwPooH8fatSQWhMSawLSZhPS79/u2VIkPUhXKQmObbTNObg7kQH4IJ3R692+yluiwgsX7nWO
DYPdWZYnHj/3+Lmv/PzXfe0HP/ToL//t7//gDz1xZ2mrptOmTZs2E4CPMeRxubhdrbBv+T/+/D/2
9re+9nf41bXbauZ+CEMpmPuoLKRedvtjD6I8ByDc856DaZxXd+vf49RQZ1I6vr5DcIsT7CEE09Dh
1jLQT7xf/YL4CbafAfTA2/Ol/t9b1EUemyg4AI7XxPfJPQTfUUWugX9LJDzS/BpdFyEhcVSw3V9C
DbxCDZzaDy2ROv6Z0KLt/iyLXeLx9fqlP+u1X33x6Op//evf+4Hve3D3widZ0LRp02YC8LH8sMth
4v9qhX3zv/bz/t23v+W1v8OuV8M1Vl9s4crY3RPsbVZNfveqtn0fqOL00Kj3ej5gCyZbsOiFqVN/
2aoSloKbS9ugBer2z56hfle0oQ6wXJ27fJ2bDu55STfs5ou3QMsBP/3OhgAsslKoM/wuqQ0a14Gl
a5Nv5ttIcIAnxEOHJ12SBe8JHc2GbMhA53Dw3kLy3ppwd7++xvU9twc/79Nf9SueNn/n//DdP/HP
H9xdZhIwbdq0mQB8TD6ou10fKfr/3K/93N/2K3/O6/+gPT4Gf7dFdu/dzOBSZbfAH9fWwoR5GxYc
VdRVtZmGxrYvlck/S8PmXiQCxDjYVfmO384IgOVJ/fb98gM1oDvoqqrf7zEx2tsFhH5KYhD0AXrj
HPydAn/IKHo7g1KRLXhXt42+t1XsNGXZURwkbiSn5+P8mYWHobdyLha/uHp8/fD+nYtXfMGbX/kv
vcL9Xd/03T/xz568czH1A6ZNmzYTgJ9KW9xtcbM3vPKJyz/2yz/rN/76X/DmP7m+8PjKVrPG3V9U
43H0TStdimFUebr8u5dJAEaVKu/UH/8HZgVBTzHN7m6RxCbt2UsrQi8s9fhDPVzNHRgjC8bDCkbz
Cj4erCNtAZ0SMFnP639EgQVwIuZcaVvKn7xKd2oK4J6I8LPvA6FOiVT8eUbXEImbNk6D5WK5fPTw
6uG9OxcPvuhTXvHVd8y+7a98z098zyYkNG3atGkzAfgpsHuXiz26hj1158L/i9/6hX//hQ+88Pzl
stw5TJQpe537otSwHB4bXO4JNnaqwPsAHA0NUlhu/ekwlMbBGTFIUl/ZI5yQ0ogexNrPBQxRMU+S
lg7zq2pe/x7+rNz39mJPIUoM7HUXeqXO98ZlnL7/Dg8JS0BNqmyDegPaAnC5P33eQLUQPAxetGtx
szzaqMlXSgrpXl9cXlxevXD18OLOxZ0v/vRP+PUvPLr+K3/z3R/4gctFr3XatGnTPibF8dlnOO4H
et+7l/5/+uJP+5KHH3r4/mXB5UGhr1Tb4dI2By5kqVkr+vm6lx6COkHLUJL9VPPWQ3kxouTgz9B1
+yMgcsNM9oPElo/y19bXQ9ctk3E83Kg772m5L/Totfr3cDfjmCb0GmyTFYClj7LWjzyiLDwrgYLy
WOCfgF6UBEjVIQPs8s7F/etHV4+uH109+sNf+Rnf9ls///WfdbUefuPik6hz2rRpMwH46D6cu10s
bq9/+t7ye7/0Z3z57//Vb/vrywuPL+8sfrc5Z/cwQIcAB1MXu033oVX6GaL33mtmVED4/1Fs6LnI
1/A6oZf7/h5iHjJfTRFAelWrnPg9QK5EUUcV8bEyZ5bAg8CQU95C+3Q0EDcsZ72i/ENn5GvERroa
qNwEORWRH81qhNAkwcpAvnUxUJIc8re7Tgscr6cnHb63tLAlF4BdLMtdv8Ly6AMvPPcnv+Znfcev
+5zXfgpgtgJ2MZOAadOmfYzsrL3L/cuDuM9Xf/br3/TnfssXft+HfuRD7336iTuvYXa8cuXPjPba
dYtdOtZHKdzIXGfuRK1LEr8hDuRd9jBBDx2O236X7tiHJAKBWrfAomUoLcanoAWwUd62oH6UEM4b
EhCxI+nWB6VE/RyIsMkQY+gDmvvc/hUfQyT8qX62EhgWbIcI+VfgcEj4BmTJolZwDPbw8fX777/m
qVd+9X/+j97859/53vcckIBJGzxt2rSJALyozAZm9sz9S3/jJzzxusfr9fOXd/1JDgR9pstTBDkM
eGVY2bmil7U6irEkVXuo4JHCtZcxQKFsJcXpg3ZHnGIQL9ECEw//gSpOH2Z/aKuKGYvwMFnvAYCv
puuP17v09cftngkBESEn8S5AAnTdOoldGN8CM6xMvlLCA141jIkCjq0TfjJoz6HPcRTDhXFdcpN7
3uSaw702d7t/5+KVz//I8+/7L3/TZ3/fV7/tNW++bHMK01lNmzZtJgA3snuXi71wtdrv+kWf9vY/
8jWf93ce//jDR09cXDxw7lEzk90Rmkch39u6wHGAPsjXMqGP2akhLsjEfws7YGi/6GEPePJAELz7
OGIwJwDCT2wdjhhVj9ep8wWVMFDx+za2oG2HnpCXFvcp0CrignQZ2td3y60QC+Q8fdJxa3+AE6tl
SQkPCu5/dx7ajMOa2z/CbDQvsJ/r9QcA2JN3l2c/8qPP//if/Y1ve/dv+NzXfKaZ2aUv01tNmzZt
JgAvxq7W9crW0M/lSAetsGWHOzhrUCXfAn8L2tRPdheEIYfsY0WJHoIdfeBMaORjpe81l75M9CN8
ViKwKavJYpjNQl8fAdPXXQQmFdKfBeL4B/XhEX8vcoKjzHuhYeFmefjQZPix/w7XwT0gBV0J5x7Q
AXS4X2O2K0qw0vAhnat+NnpS0pAUrA0ZAf3yJy6XVz1638Pn/tRXvfWd/8YXvP7nPF5Xe+LOTAKm
TZv2U2dnuQZ497hL/e/98rf+qq99x2d8g33ood27WB64u0c2WObNh9NKF1HkMsVtG4CjNTW3kbRN
/7s4wNepdKlqp51+Dzv6Wzj1GP8s6uZAtAoSQQEjELz6Z8Uw4wBBiDQ4UXdPCHBc1wtbcmRhJS/+
XpoV6HTFVs8uSJu+K/txUsJEQV5SMW/QQU8OpQWzoTvO58ZELMqdGSEVIeAFQ1EeXJbUktk+3+J2
ef3oev3Fb3vtV/ujq2/9lnd/4D2TNnjatGkTAdj7UG72eIU9uHPxzINnnnzt1bVdudsiQ1jGleKx
SoYiAGVApmiu8TVR2dCXJqyXfv8inPoJ0nYBvuUiRLCIOO3b0CBVt7G9oVsHXKH3f2uIB5T0BkTB
i+P/K4wHLegvWmUf/6+TB3WNghZ/j/+fB9pimY3gJIHQGVhPPGTDQTYYjnSQ9Hz7vUHTcBAcImgV
yJYIuvwv+pCIzFs4JWMS/PnM0PnylvzYsgD2xOOrV/3uL/+0//rrvvTN73ju0TUe3L2YEwHTpk2b
CEC0g9CP2R/88s98x7/yc9/0bz/x6PEr77o96b4subZtTPUWNeSBncErceBO9LrF7n7k3LcsgAOa
vfPA7YOiD64/nnj60afwZQ7AayW8vrXXoW8caZBl676AOFS50Kvb0nf7w/CEd+GDJDnsAv2bRZEd
HiDshEGa0In+QXXvnJ8dVfJhFSH9FYka1XTJhHg0UqP+/CVxoFZOpgrov3Rxv3j06PrhE5fLK77g
U17xK55e7F1/+Z+//7uemrTB06ZNmwiApYr+cnF7x2e8+te/8fVP/3x7fG2L+6VOuAVA2YuFOsJx
4yBXMXPWA1hQ6/OOGfeqsEnociw4RN/DhDjtJ67aHpdWttnhC7h3rRJ1nYAnzs6Zahq4sB+ulhmP
IniB4xokJPjvJUwtnm79dOwJCR2ElJw4BdwVlYjDex7bB0aqgDRsyWOezBzIz9kHwI22D/pcg7vV
56hlVghjKH3otGYz6If17p2L+48+8vjhExf2qt/1JW/+S1/3pW96x4cfX9u9y8UmFDBt2rSZAJA9
ul7tPT/24W9fH11dAcs6Ct5pfazo4KPOMqSC44E2/k4Y0i/xxADkIYAGsl8vWP4oG0hSw9aJe3S9
zcLU//ZvSLFHlgjSfj4KvT9drTzkEOD8qhMPIdTNwlSY73zJHyRBWof66ql7pGvNOcqadB6qHKD8
3vb5F8kwJVmpkiJg4xMOGZ6nhOvu3Yv7Vx9+/HAxv/x3vuxT/urv+YVv+MIXrla7WA46F9OmTZv2
cZ0AuB3Y0/6Vn/26T37rJz/zi+zhY/PF7wrdLIrvKpYEpNwufo+bpV38oOPT/2M97H37xvGOQWnt
NFSGMkPJM331aEEs8SVIZ/bAzH6YJ+6Lu9Cb29Wv4rK5/2kHVUCxS89Jh+gXlB+++H5AOAkEsUGe
2TgV6GPF7tQGqn5GZ5AcDFXu0ivzGTK7vHtx//qFx4+uH18/+kP/0qd/62/9/NdN2uBp06b9pGLm
+WQzRyf4w//Ol/3jV3/SM2959L4PPXf37p0Hubwc6dMhCbgYsjjMFj2wcxMjq1ybKl+hg2CtWq8q
ShoAHFLL0gUjRLdNBGggWHP4vG7u0BhVfTCm+rXIrkdoiAgQ9U/TNi0aiY4bbK3UFsaBMHxu/rmZ
qc8N6xpmLZSFUOcLoDMCqM9GvM3yGDwONXp6FsNnRz+1S09XusNm65VdXTke3v2Eew9+3Z9+16f+
2W//0XebbZLXcy5g2rRpH4cIgB0RgO/5sQ9/6/ro8ZVfXCyRtAYWF/eCEI5bItJx4s7vfVsv1e6F
87/R+ZKinjMu3gNTrHZZ897DWiCIgOgw4a6wM1LA8UGacgj+ZpnRsP03oGvsFspn9LsKuldGu/vO
yQE4aI8r7YhbcL7EFEFguCTcpKSFEBCUNvgnWwgVsAKp9quWihv2U5kqMEsrKQT/mIhQcrZc2OWd
xR88fN/z7/8zv+Ft3/trf/ar3+hmdg3MdsC0adM+PhOAFbDXPX1veeaJy9e62SXMlsi4xoPdW4/e
TUl4hKSHB+WMp8wxYAiMMsEqHMRVMuvY88/jkTkUPW6XVgGssRsI216kq+Gf3ofXWiIBEJsgUjyt
EIQ+zHi8YoDyLRbI8RDDAtGSQVf90Pv1zte0BfH2vSSqxCuGBX5wqPA1EWr3lpb23TPy4EGCqD2d
fqv62iTPgsS5kPFaSX9+G+qDPJthci9g9+9cvvIj733+x7/xN73tPV/1tle/adIGT5s27cXYmbUA
zL7v33r7P3jD6x78nMfPvfDoclnunuyv7lZt0e+fEJYhgZgG83uN9DaSHOp/e5xCY0GhI5yNuFaY
+v68yw/qlfvoQ5HGgaWJeG8T+J7bAPF20ueC3IMsgCOfV0iFqkqaVv82ASF+DmFbQwV9nGp0o7VM
RRTkPrGKUfmAM9e/vSjoPT8P7F5XjZFs//aRx9c//sSrn3zVb/7T3/GZ3/Dt7/2uC1/s8bpO7zZt
2rSPHwTg57/xlU/fubA7dr3axcJzURhKx7bKHCYEMC2SMHXwMQDo5D27ZGsBqdG7xnawFbHTFVju
xDTHsLSu7WfJ3jt6CQqqnnuA7V+mqAOpHUYwov3IwD6IYo+AB9mdvm9TG2y/A4Sw0J3yHAw9FryH
G6DDj+43khfmNUccRZk87us5aQyMHhIdBhy5EpgbAZTkIF6He95sALd9AlPi8draSqnzCVZFyu3n
PnF58apHP/rwuf/4q9/6rq/9gtd9zqQNnjZt2sddAvA5r3/mjZe+3DMKbp2xP9L3EaQfYmCJkUSe
/sjFv20TRKY4Mxk0kykBEBxfqNtx71mm3uGBlx55bsE0OPVKOG7C55137t57uhkuJIWeWijEnhgD
qwUCIZ4vwM6KJlf4zPpnfegOWA+JgiQQrs9g42NwbFxHQh8MoNxECHJNiY+B/yMlhpQMoZE0eR/Q
pBZM+1/v5ylqVVAKJ6jNnUt70j70yL7+X/6Z3/J7f+EbfuFHHq82GQOnTZv2cZMAvOGZ+598ufh9
W818PfDQboS1zZ23XjF6j3oLPoHGVWIuByWgEK9h2mCl5z2ACOvBjTtzv3sRZHPuwchCm+pnxjsS
qylG9/Vrjn+9keqw8h8sEPbYqkjEkfgnSRmjM9+5bCH0+6U6iQRiE5VynF1QFKAPD8o9Y+Y9IgIK
3f4G/7ctBPTq3E3Z+7qAkKUV0fZcml4AbYekoQml+pVEEDwwaUJuIP3/OGwg3RdnBGGxdbUnHj9+
1b/9jjf/xT/4JW/8Jc89usbTd+dY4LRp0z4OEoCf/dqnft6dC39Ch69co14Irm6WqHIzuY4L139e
vS9Gz9xLFUCjwUP28nH4T0JXWG+LBDiJICgkDQcUgOYR3PNXQ0cR257DppVwvCesYMgtALj2UCoU
HQFdYClgpP3LkLU47+FrTz9W3ImUAIzUMMVv6LuHxvs2bLlB9k4oTqKJqPQO+PmD1xCtD27SYdC5
C05GLUIzlNZ0PYOLi4u7Vw+vHz7ty2t++5e++Ru//kvf9BUferTiqdkOmDZt2rknAK97cP/TLhx3
D8woGUJusDkN+ANZrjYJ51DJ6wEv91Azx+9rg+ZctSZGG+gwAk/Wb/vzxTXBzbBD2gOWn7UcFKuW
h4dquvebaVCP2P18m8pHLX2MwMLn4b7zI0K4HS0BQd8aiDz/NTFPuBK3ckNAev5RkYeRHbcwgBkk
g2PiQgmBp9wsr0/K3EUhi6wbFXStyJ/l8vLi/qPnHz18arFX/c4vfsN/+we/5I2/5MOP10kbPG3a
tPNOAJ596t6nX1wsd4/Y7TKqiqsYkEj3CArO3xNV6irj6pLH5DkcDmh0mV8fhQKey5p9QBRyApKg
iwRYaKdbeBG2r1l73uLph1tIhuKd4GSJBhfXE1RKokbkYZ2ub0OUIkeBKzBO2Os/gPIiKCoD0yFI
liaOixjUBkiCUK094qfphV37/JF6ubxrW+LqsLt3DrTBF8ty9/d92Zv/2u/+ok/qtMHT502bNu0c
E4BPfuXdz7swvyvVFhVdHLzZ22pLtejKg6rYhvKmDrMpBb9WynGEMLHrRCIe953UhXX4eLe//oYt
UfFY5NL/ooIQ4n3kwOxx192r2ln662axBYP8dzw7IAyMet/yFoYJytMfPATxsd3VvTpD6kW+a7CN
ssD8+5v4ZMGiFLciPfyf3CEkRcg2rzHkLNhog68eXV+tj/7wr/gZ3/pbP++1kzZ42rRpYpfn9GHu
X1w84AErLfOQqv7uhCNZLvrKHUae28PvQL233cpmyPCWV2uJCG7cNRC0eTFQDxnplxlnPdtHkOq9
XHWoWPH7Z3L96F3pEF1UCGbl5/IoaGD8jHYQmkY5EGYdAtkOwtqdshAiM0B7jvXb2p2PUKOCyyDe
PY/EQvS9/Vwi6U64D/KQQerHz6EnnpkL4eJiubs+xtWjx1fP/cmvest3fOjx+ql/9p0/+m4Admdx
W8dEAy+dDWmoX0Jzs3WFTZLlaedmZ1UK4Ou+AsI9b/qnSDIjZDUSPCzxs3ePmymEK4odqwv8vnZW
ff2oOqX+MxIRDyULvP7oGztf4Vedr4PJd1yGDpUnv1P9KirQ5P/kvuePpRGrJRKUnLRgKElZvr8q
sFMRI1ECZ1kpcJMItiOp0KiNr0MJ/f44DyzQDEm71k30aQ10xHGuxKIEsVI6DzUmUOgGhHFU58TD
zD7y+Or9Tz771Ct/zTe8643/1Xe87wem6/so4FLfI2ea9mJyvClZMROAn/qD9Ye+Aiq84jcqIUC8
8WjVfV/dywVJIa4DQgBSe1yRiMM0+Vq0I6wORtT3d7cBzB9nCCgohN1ycWLy85Cqf6NBwhgZMdxC
8PH9LZImK1gRAx7Tg/y69kSkKBmZMdACuyIH1RHik55LQayUrtsiV4DLfZUg72UekFxktcyQb5xl
1sjB+TZ3e/jo6sefeO2DV33Vf/bON33rD3zwX9xZ3K/W0654T+nQX+T3nCz2UbVqPrpr+GiDkxcA
3vd/8NH1DBc/tYHno3l2M2+YCcDQ1q/7ZXCijR0FoRzrtKISAMAq2tqCwlaoansS4CGgtaqbOAJ8
lAGQ4h2I0qh2nhw0BnyyUKfGaEQKGFQpb1P746ZKrTaozyEnY/JMAiEPrzt25AEZVUB4WAWt7kBU
L6V0HnOnKtgCH13w4YsgEMX3EqebCgy5Z9XKED1bx2O1q+WOX7ZyNnpj2QsdMC7uKDRaUmf0F+e2
08AGSmVGuXAMvj7SeL/obOD4Pfcv7Av/5Lue+Uc/+pEP3VncH68vYf2aAcB8Zm9zlHSz6xX2wvUM
5TMB+Kl+N77ul6GUXS39B4Rhzm/k1EOiEKoVBh8kGRiETe0wYMAid5DNZbJgrlot7NPvR73+PZwA
5CqMJX2z/gFOICIpJguiEH/2cqi6RQEPgzs/CpJKn5t0nEbB41T1HOAYToLix/NhFU8JadIdGKcj
fgO0qjxww+QjrormeZE6wfX674CBvMSLdezI/an4AHGTSLgTION17Q5eFPfT3R49vn5o5lduWABf
R5LRuxE4tI1sRytj+7fVdFJ7PSo+bgs0238vwwRAn53+PD/8vOXwu1cct0R8+zpv33P4XXu+tR/u
bbZkadd8+N+rFR++++DOU3/zu97/H3z5f/V9v/ujClieEaOZSswE4HAYji2AXAmv1BO25MzNeIhq
DdVs75TLbYuzAhhgW8nPghj9wmCb5+RiCH1Sq6LuCVgpOsSzAihm97k3ztWl3IfBQBz3o8EDeEr6
l51w6PmfhsZzxW8D6DYyOVYV5DZYaV6NYiCdhzrYhuSKKu98XaPAWz2LMONgloSWNIHVmYKOpqiO
QJ5vSc2UTl08AHDb1xcoTSPCYl0I9/x6EL8Gv2eCpK2FtPNgiHa04NBmJ/wQ9JiPwiNpV0ysDG2u
o0xKRDxqIJRVvE928kwNUCQbo2opMWxft/kpVM5EEt0Xn8TRjnAc6JH12eO1XK32Q88/etdSVFwt
2eDLW331S1uuHq0vvOE/+a4viL/9ztJT6qt1pgMfxwjAVwSe2u72fOQtqFLeC7YeyIQ4I91DRmtY
1sKQoCYFzVFS5djfX1ByE64Yx3ydKIIzPF/TBQ/Rjzi0SHBzLVcPpfwVRb7wlQz1Vw6pSP+1CifK
XmZYhIU2yriF0wIi1iLRO93Lhinc7R4TFQ30o/uW2heSazJqoi2LU334hNQgPJ8hkoycjJhpwhgu
AqgUHsfBDAGEGQEAdgrJsSh+FQdDizNOCpsxCIJ8Ag3Crq2y3apcHAPVctgSWMJZXQFb6CEcqupD
pd2C3HEK9vr4+y/IoazH92OpPjfzXS1HFIBRAgqofXC0r4CuguQc/rf92/a1Zra62xLex3hdK52F
JeRADXGgB+2LL3bHFQWp0JHYEoLbd/7Qh/+7K/j1Y+C5ew/uPPhdf+UH//X/8Xufe992bfcuDif3
0WwxfJwmADGgyZ56mOC2nWnrGFTiLSNKWi+qYFjs/+cKKpYsqZIddAw0CdBq0yihSFS1Dfmmwbh1
NffFDCvt+yl9LlcsCCI0ucqphvGsnMmgOnW3+shIiZmqGrLf9R6Aq3u4g5xE9sUcIRFmM8YhKc56
KHuTBi4zGyhCYDwpF3FRoExMvHhQqPQNpM2DqlNWgBSZbdFGWzVlemhjaW3+jlL6GvvthyFKFaEC
lPde/EJKblL6V+zlYNxS40RjlARTwm8BNQLpYsA6C6e0yHycSPfPkp+XoDZWkE3Rc90DDGTcag0z
PW7rargqONWPLQQc2g9ypswctixPXvTV9Uu37/3Bj/ytf/xjL/yN+09dPPhfvve5b/oD3/ajf8PM
7P7l4QJeuJrrmx+nCQCnyB4jaA3N2n4Ff5PJ7Nq953lDXRfMiIUVXQSEl06cALcmUr85Xm4cxFtC
3xmSAzg8ObsudbyW9xGhWhyu2m1OATBfFq3K9oKCFYN0cfyBsgCXoTYUSRUnTsHphuFDhY2R4qHH
wBxaQHXSWFfszrTR2IGLbwQhrz3ceXHNcTD0qPNQ0hmnJAnD9rsEwlj1+yBhLO5PxU9h8dwPAQcM
gmx8Y4/vBwY+4cRgqLxCWyym5ybBd4hlWIGkeGo1Hf5/FLO+RVKlF5NaHnGDaW8KhCdZEZG39v2Q
d3+TMY/PIQ78GjF3MA36ljxdXa8P1wNSslxfr+vdJ+/ct8vF7K7b8+97+L6/8L3P/Z4PfPj6x//N
/+mH/+IxR7DLi8UeXcPWuXuY7KyIgA4Ok9yFn8hxZIJvNSBUhu52nL+j3i1X25ujdE28Qw837jX5
gY4tUOEGTyxJClfWYd0v9K4Pn34xM95KiBA1Ef947vOCheeK/nyu43IK4KlC2wHTpRobOf1cdckz
RihtA9ReOts4PV4wQMJPHrr6iPkIJfG0GeInfza0x3riV1sZsC09w6Y/YGHeQD5GaAM07gbsXXlu
MKGffYxYKKGJzCEpdPPVVRHRPJMuScSC6m1wS4AYOOEUjHkGh0nA4gbNlii2z+E5QfIdP5O6d4fV
VqNh0dii8XAO2mgecVMcPo8nkbOe3yBSdBaFUO9twCu8Y0O1OiO2W0DcilVlXgHWogAFJxdqP3P8
IJcXy/3tmi8uLuzqheuHeHi1YsX65J2LZ/8PP/fZ/9g+cm0fenT9Dlvcft//8t5vvrpaj+0Vs9kZ
OOMEINd25GalcuE/j6oVJtzFSBZg6OlGQ8juNhj8ynAk3EnjPgRsXiVrcsZjVkLsBOGEMLj3xGEw
Zd4rdQ+bY8GJliG4//wtsfI4EW15WMyJZz+hMWHGafv9MS5YGeB6YBOnFUaMm3NddMmihZHRQKYF
OWmLRD4mSZN+NpoNocqcWxFGra5xGyCcvxQYehbZBiKdg09GG3i+A0XOs5N69QQNunbr4c2FoUaE
oh51QPr4442KBRVl8BFuWG4zIlxHf2Yw3czR7/AClTjJDHliL6ldngd4PyY3XGds173B+fJZ+/vo
0vwbhuf8zhbJKidRe+vBFXLD97v5mBV24Xbf3c0u3FbY1Qvve+H5O4vd/b3veP1fM3f78AtXX/T+
e09/8M/+vR/5zg88fIi7Fz7nA841AXDzY+Za0N9t8SWxuxVrYaki1134Dnl5zujNlF2vIvvZFPQ8
9oXVsaXBLIaC3bNjiSpxUInj/vMxnHYfOUGXV94TJnCqyaQDcXW1bal1MPiBUUfBavi3Whosh6h3
1u78Rn+LuhK0epoNN3LrngMf8u/DsGXlcl96QtbJqBiZYepp1h7g1lAUy8INIFUvqmAfPTY3eR+2
3yHtKVDCUfF6eP+a3m87VteBgcmL95w1HSyAgSDEKa9zDs4c7ETyYiQg5SLFrbdNh/94XJWltRES
Xo87yuJYYqrQlS/z2mQ+U52jgxK4tHnjRWHEz5eRg7zRg73VjnD/FrfLJ+4sz8CwPvyxF96/mtsf
+rLXfqt98ifbpz1YvvLr/8Z7vunHXrjG3Qu3xysmG6HZuYmDofe0tmGvot9aScNujgYETXXRl+ZH
RMVV5FxF7Afy7rQEvCUhYVjJVdZHHYWrlp5Ufab93MLxYkMv1jhdSxm19Ly3zH/bQADBqJ5gPaO7
HCn5KyEcwEUzQJj0PF5Drv5N1saOvl42JEByvUFWOasuW1QCRBD1Ga2gc3D0bVgLKPIbDPITJFC+
CSWSIwQCSmJOfApUQQ760I58piRwwwMsFS7Wx5fNfdusWLhJb9cUhiClrHbfwfl6J83yVCcXCYgO
x/TvcJNKtszCWIPaCDly/Zwu0s2mQlOU6Ww5zOZTjuId8o5H9lEOvg0Z2e4J+u/FCURDqb0RfIz1
rRInrXIrZgKAEIw9PUsPsthIgxM9unvxqBQRdbr3Ln/mxyR+x72k2naz5d6lv/LJS3/low/juQ+8
83u//3d+0dP/3e//373mV33i/Qt/dA27SV4xE4CXW/hv1a23oZORilwicnGnQNZXVHrgRmoJHsNk
VR+Jkq3HkqBQlUMh/dozCJfA1x3d4f8QKhuBT9ug4AEyQ/w52/UGh5ACNzku5L/tzm/QYmgTzY7E
x9ATLuvbFe5FDEKfVGaIl6aTgQABL1sLZ22JgaN8ZEmQb/g8UvvAj0OBaGREzSnL9bL8c2ifcCIX
0BjnTNL6ACJK6aIwT3Gs3PrjjRsXMEXDPfM1JIKGntWibHtR4p0c9ObYF6GZHhFmNeFsID0Cj0ME
0ub28l7Wz9IbmocA60PKcJrcN/TcSR9eSz7F9YSELQUy622VhjQcLwsDaMVFNtpDQUIYDtb2c9vw
MFAgapoEcVkfg3/mVer3R5Nu3T5KySpN8oL9IbAjtF5npKCkbLu/dy/8wSueuvfGD/7wwx/5N3/R
a/7i1//C1/z6Nz595+I1T14sMwk4Nyrg/8cvRbnXazZebTmBKAAZ5eek1S3M+SFz6MOolx/5f0N/
PXHKh2OvQ0EJpQsCPy5SxSnr9sHrNeIVSuvfNccAqL/L17LLwhdU/Hh9rk3dF7wIAW+hFmwfjvKT
sxsFMdAN2gkQttztLqx9Svs4xMbQvWwuhKpVq8KwrVG8sCWNtHNlb0dtg0VQjWrLhKvq9Dtuqjvg
FXFSvr48UqI8B6OtCG5VJTbEneuq2l0ehm1lEt15SC1TLEkjA6HNEtsTN8CZ4wBm8i2eNheDtPgh
0a1XmgveaWC3DbXLh2JjNmIrztZJPRaoN6lULev3sa/ZmkU/U//qa+DRxeJ37d5i/+W3v//f+I1/
9V/8icerfVxvB5wVAlDuCx8hbjlIZWu1hmS3bF3kYrdqEb3uBUOIrfLfKoY1QAFolURZ8RG0hbg7
Tqs2VIx0hE+m+iOq4J0fwAMkjA7DwqLIscnAliFMsAtyAOXv98DAaDyARTD7sUrpUCP1q70nU9zW
UIi5w+eM8gyVk9r9VwbG5GyOz60O/t5bMe0edgDbl7gM2u8Z3OTMcJJjNIxpAQKVSyv6tAyNACgD
1bAKAPJWGzJEnn4QvXfadOstNVgWtHLC6Z36WBJkoAdyq5ZZOrufPy+zPS/9RCf8cSdwnoY/K/Io
3wlq3LQIfa29ENjmgVr624aUeaq/apNYQyyreYyOiKIgJPRW5afvJcRCKnqvYHkkP+MF6sU/B9Ak
BLGts7UlBzLgHbVC87PZz1Db5Pj/XbjdtRWGj1yvX/W2V/zxv/yrPvmProBdLDYTgPMylM2muD2n
O8eHSh3kTDqsHFbaZBqe9naLF733tDvE1a/Fh0V41u+NRCA8Rw6RwS1X3/ygRW+ht89Tu87tADcR
IpJOb9woaDu+pj1Uy7mLUWIA+VoPMTfMHIPaMJTk+OIEq1KgYgcTepoW5heYjIXnDhCSG3WGof9a
nT8Uq3apEtugZB76Cuel7iW1/jnvZXEu1ga/6fy6pFYD1ozQowUTwAzeLwym8p0QGWoJywZLNZjp
PbzJEK/M4zD05m6jJjniMyn35E2cAuRz1UyWmfLb07mAoR5sYxnptC0DgRYPx4jamhn4TpsEGrC3
VWA9ewaUawfhI/V7bTqXEhtlMJ6X8NBp8eN6srfktid63uciGoA1OO/oA7KebwbxohBHCn3tNg7l
V1je/qlP//a/+Wve9P+5Xs0uFzefCcB5xH4U/VqEoS43PthMk9oDHI0C0L5wDFZO/ACQd5f7eV4O
bGEYQoxfJKrSc+XhAqnLHrG7VFfV0FRe2dkycGELSPv5rbbAevg/goBBaAL/nQdoVAc2dYWw91xD
YPBe6UMgfF204+0DGRbaqg83LUV3HKE+a8pmtucdFUrKeh1pmLuvP1qxA6bKj4jzGRyHmnQ1+jXC
BmRQpFlQdN49SBiPSJE42a2FrIIM9XbGmQG26udCgyT4/HilaZRnBOp+MT/r0KpDfmQurwkkiTdG
NSxXy+xLWpUdW2mhmt4CY7Wty+14I5nrFjhJz4KPdaoAzMr7lHCqQj1UtjhCotNcUOKiCsOCDvGT
hpottUpKQWhd9zGrTFhvZ86pfyKzFTi8bxeLLdfXWO3a7Ivf/NRv+5Zf/YY/drXCLha3C58JwMs3
9ks/SEfU9MXQVSNGDmW4HzHTH3AFxiE89BbAdsDhVmS0WxXnfeinBUSQzGtew9Pim4ZmmO+AB8ci
3tC2GzpfPjiw00vpVJVwvc6tDhckwYVgpWXghZ5CCx5uNETHL7OFyWtTxKM4AzzpL1sTrmRMKNTX
UjJSQbcEwcTfw6N9kARHp7AVlQjEUUVV6INA2e59qs4DgGTdOTI/QyIiogpcZhLiLVjXdq0+RJz4
BuUFFJ4Oh9BnHYcWPbfE+IGcFo+K2Bnx/Lu2oHQbt0gqWlvGZCujFxaep9JDC7JXvT5IXIIjkq4a
UrOBB4c7D0WBVDolCSEhsZBuQvgdqG0l7xJyghE1f6ptq+3M08AsJ8MNqXVtfTgVNtKCDS0gKX6I
rK098qU/v8VtwYrVrmC/+NOe+b/8+a/4pN9+tcKuYR9XScAZzgB4mJANyJqjw/3co2TYbHtBOKNt
L3pMLbJ3TCvv5gQ1B7eOQW+upw6mK4bUr2z/I5RFlngMwHAk8eFHel9j8qOCRFg0AbavXoq+NAru
ep3uHRMvNVd9hAKzg5d1xKLydwFAAvsbwYvSq0SxWx72PCqeWmeY0RlwRkt63Ipkwz1MhFdUtV7G
g6Jm66ciBTITCmGknqz2aDBQ1/XdmYiQhCN2r7W8U7Y6XX+zCGszpk1nq2aRo1fKtShQCN5kD77c
9mC0JyBmcaYmrai29kyoYBnJ24aDBV5HXj8d7KEOtREJdctwieW+ekpULSB0x5MW+FCMK3pJmuis
em6pcfPTdY9QWxPDT8pDqUvsxUnrxQunzORLfkwC1kfr1a/5Wa/4o9/wjtf9ljc/c+fSrYsmzQTg
5QkF7IKx+qb0AO2BAccH5UW5cx+Fd2BjJULGt3hdaIVit0TglUR8ShhvKKKr+870QzFYk/Iy7UCC
ETEIGqlHvJO0IS9l84QYN/jlhrvtSMSiT2XzdLn255HOSxw0qvgXKmhA71OgP1k8BEBInxMFAyJO
TGp3qmP0NbMhN1PxjNucxfjVGPEL8PWOdBtAwbrUvaAgyAm4hV42WPip+jzuqSVRZ+P5jyXJTtFK
xO4JljRnwMeg1xsHHke8CyiT3k7T6DG/s6J/gIz0YF0LINJl7Tn5GShZVPXelR3KfEVHWWZNDNLz
Q7X6icHTCMN/xRHAqP2x+ALH8vjR9fO/4ec/+x89vgKuYHZ3mQnAyzX6lw4QhT6asPqFyt6Fd7tg
ejMdSoovewz+KIXdUL7sKKo7T5iuB7Y+6NBeGNpmsh4fBQXTDHoXYMUoCvq4MhklZBj8r2Ogchef
AV0xkFakkrPbSXqMg+oIVAanSH3ALT9gDAl6dI1jFLcxvG8jjQOpzAIXhsumCu+196feCJTSR0Gh
7Jc/Z5rdAnaDAt+PNEcYnb27zqtUXBG0kZE1LtaQeyN7iNAPyRPyxSwOiuOLYgMnJrBQobGRDDIG
T50JlHzoY6wk/OlozWAoMiQBPHDMvCixRSZHriT/Qd06vUExN0psZYsLFf1bQD7C41vMlsWXy4cf
vn7/1/68T/yyB3fcH16vdvFxkAScVwIwkJyD7ZbgBImajkgXUWyIKBSE6wwF1l4iQJ6eAUlhrjME
GLVYXbS1uLTiZRDSkvoeuRCOEnwXHG+5m44iRGH8JHyQBlmEgXXKc5gD9ljB616eYHjbqxhdn00c
fMpsvzAWIQIKtMCzSK9HXv9d5Kpom/gptMszpAoryXVOvUus92A7T9MpUFeDYR1mRr3gwLkMD+hW
E/UDaLv/vY+3AzBIcD1qG+yTSeyGMp7eL1tk+b99UChQllPOeeh0KIaoW86/UKJIKpplfYzedl4d
r9HJ3hrwNMOSnl+Yp6h9TL8Xp1KJ4btx/MYLw92Lx1d3f8/bX/NXfv8vePYr3vj05cWlH8C7mQC8
jFsABPDngyTDK2Ei211XSoqXPFc7RtAo/TdzCNQIsgr+xO2mQEgeB4CSZLEl2gGtbF0FfFAGfqUm
lh1eShx4IN48V22sY8BDRrCcMHHvssOaXk5ntyt1l6rDuXWA3L+H1Vsi/Bn7oJzTzESvCEGBxYWx
rn9NqvYKgngIP3S1YY5BsIGuz0WSGGzkU70n31vPLkN6vMEgE+nVQXcVl3GEVVCCgiEMcPnt8QiE
WOeGl7aPKwoBYX3EOPvj0fQQ+Pp6m7cAEgNRGyj2OAzsBbuhhcG1Au0xFT3iNtehqkabJ4k6G16V
5cxamrYFwlkPfBI6AB2qZbp3LLDJ1OpMsl7uu2z+hmAJFM6ThyijjwGxXhpxSFiYs2ExLRAnQv+5
5RBRzwupULtzuTz5wX/x/I/8W1/2um96+yc/+SkvXOPsWwFnmQBEx5IBo7BW5Do5mpTCPARA0Diw
rHzHHjQSkUnR7db+MSrijihDPAYfKqrOdv3EM8+B0kvgHiHL1lgNRMk1xfvKao0CSV0A9RfYofvB
5LaE6hgFZ797RGL057AGulR8aZUNoowW+fKHQFFRNOXC2uU6sK7FDIaX/aZIDYEIt9IQZWNIc29s
cTkpDNoXlmFvpCGxrn4YCV62YKbnMA0DSKLatlxibA09YiF6qqbuYwUcNmoiMySKmd5231BUtrIP
z5t5NcQe99DNvK02MvOl2SLTc7AsI95bU5EjA/Q5iomalHR78DFVAzKOneYsPG/IODEXkhgar0G7
sph5gTY5bZAAKFAa721NcLuF0BXPUtbRR/Ag6fZ77l4uTz1+ePX8a56+/MRX3lv8xTHHzgTgVpg6
Fp2wbdApU8kirk5lrLdpBfhBi3vjltc5Na/7tnG2LYc9rSS8c7dvgQknGhqA7hjHX8PDRx3WQ+X7
ZNTGM8TRiWs8JALb/V3Xcn3Oy6n6jfUrV+oRflV6YcuCLQW609UhBkuclTBUzOwGAaifFYQNBqW0
7UGUeBqE991TewKAoAu6Rso7iDoYiiK9dGpzmQeRnICyuGctgPEw4gb39++FmWg6yC4A+tRES+bg
kUQyVfO6blcQ6ZTon8t+eKsiLczuSIsu9wARV/GiYNbOudLnisQImVtN0IRo5WvCcMe/BT+vIf6q
zeaMa/JGjDgEL7Cnvmfvjqy2WVxDenbBk2Ufg7atI36GE9e1Xw0CUZNzi5Tkj73QOYkB/v7F8uDx
B68e/ZFf/kl/53d+3qu+7IVr2L0z3gu8tHM3sMY1wba0LRcHViBd2qDkjj65ztrbkQ2wC3GEugRF
by+sskRijIOOgOuYXwseS4YKgVCeFk7cw69HFnSJ1VqGJLOz8ZOpmV6TQ1JyvR2Bp58rREffExc3
ib5zDvdyCLB0Poif1WnYqUPBbnUvWbesgo7Bdv6EydDN1rX+WcUettw30PohxY/cM87PRtiBK8Qk
E/WXnzNVjo7wGMPQGzyB2BFm68Rc3ts/MZEKvz9xxXuFq9H/69ACAHV7pkvbQirOMFkrCElLvJO4
ET0fx1GhEcpkFzZdDnD2dq2RtTMeaA9nsF4pTZcEgtjjY3fiyugQzYAQTdGIpHNRoIJVZe2CfYkQ
umys1DMZtQbA9j7p86LiJsBnMLNlcbPV7Gq1q3MPj+dFBJRzyL7aEiVsWB4zrsmR5n21IdB6YK1n
5+IceKCG2dVyhcs0wcdg49BhZ/RAIgHZl2PwV4U46aUZMudryMSl71r19JBR6KTaFXec7ZSOtwrp
1KAjX5OnJGTrXZaKb4sT2YqVVcy4ojUZkOtQfURvYHHoT1qoLbh46nsK6x/xTkQn3uFdlH1k5cSP
daZb1TNyj6iXp3MJ7Ax5efGXRRLoe6iKrPEtcr613TJa+yrSHNdyvbfqWHMBIuU7umJIguyk5qeh
IvLkO2VAqmdhQaXTaC9dAABhhQShKpWgEbcXPTFJ1qp5TPTldE2Zj+D41wvN07jrZzCQhofeS7Ak
O4krlYUC8jB29jPhMzN6V432W0dEUbSFR+JFbmb3LvyZF97/+IO/84uf/cY//iWv+dVXMLt7pijA
eREBMdTsQaGOCXBE5159+mg4PFa8m4ORIRWqSvRH55UXL6qzTGcOYvAaTQZHJ8dQeehjW0HsclQp
RLEQB4NOulfMbMTcxSRKXigcZo1xYhIME+2RxSzWjRYFcQtVQfdqSIlnkmNSopUCKiEV6el4Wc0I
EQwPOa0kJRsr2UCa0siBNniW4iKAki6hZHzkPXpyrh4Y17h68yi5HPvlglwXXnW7XmqjCOVOmJth
BjcwtesJZEl0+sJySKOeZS2GNBOEPDKgsV+Di/S1Pcn6ZuEchfAVst8vZVhSutqqZApyxMXh0UaE
EUsFLBQfPNgXWogVZ8j2fR7EiCIyRa2mKpGLMxTdz3mY9zAZeuznBjo3wcVN2ODhFqSHbZ9w1pbr
dV2feurOa566WB5crThX0ZxzQwACqxkL/ISgpFlif5EO4n2dUjgWC91J5v5zyUxmJlz8qmgHVexC
hHSpU4cR5lHQaVoQl2kDNy6wHhLw1vuzMH1pVXyNko2oahj0F7T/3XuNcEU3ghSBBC0PFaQnvoAg
IRoG7HLK5Kbc6P36muAQJ4Ul6o19eVysuT3iTu2okJwgBn8+UdB1P3dlfItTgOVUB9MGxxXAWnYY
SaUyBMRIKcvIBzQRAadTrgll7FzxgBi3drbEB4FAc0PfOBmvsgX9fR60OTQJK7l53AsFStQUENK6
2iD9pUDgMjLVhuksX09USERAl5Ram37XCkEaXbQyov8MlVHQH6hwk823OqOKnonGoo90FOm8m8GP
c1a0BsrzJRGVZOSu+xhPaAHIyfDwahytuL/4g0c//vC5X/aWB1/7h7/o2V/6aIVdniE74JkhAB4C
Ne8Zhyk8t+AAaa2FV3/IW+kqXIANONgUlaeIBhlo9XAMnMZ+PEKwY3jMQiZtg+E2OORl5dfR45XQ
GiJz5/sAhh1N1XeBmgqCDWIzxlTHEOU4WS9qycjWM9cJ41N7wcx5LtK+AgtWc85aEUZUCNUedats
VfJXSIyQ70Nc4VOfjEGo0nmV3IoOXO/Izx0lLbIptJ0uyiR5TAnqiOSGkmD3/B5UE/9eQLeR8jnx
6ZKQjkVQfTjJd/zWLaDBxqiJRVEoT91qCP2w920jHj72CE4OOE1IA4zPfWRdTKux7hk5NE0CeOAU
QQNAWpEDhr2WYAC7yI2bopNO5EKRRClTnVMiTau2kgMi979KbgEqYLbPsix2uV6t9oZn7//cL3vT
E19zGXlAZgJwCxEAFBKy0YEFjs/+MnZHkaTVE38MmkRn3a3mXFODdGYd7ZP5sccsQdU9B9nQU8+K
dl7Af/v91JP9lYFjipUw0pS2ixZsG5iEFS2Tcevl5FLOnrTpoOL1HbpY6QlXBMwoiemId5+Gx5CT
pc0550nonXstQ1kh5gFjbfggEzsk+ykeqa6zw1LWwPK8hTKghXCYZxe8fI4IO+1YYdsCToVglBHc
aa1u7xzBwmZQFsQqlUbLex149dH9hhVc9S7trpUfsSaUHlovA8xH0D8zYYOUhAFWzAAVCTRygh+V
SJlrAHntaTDjM/IxXo9+Qtu6hy/hOYSFlABN/ttjS27HdcDcfLlY18fr1fe9/+qdj1bYOdrZtTaq
uuhw1ld5ccv1Ia8QApiOy/vp6HkTisuwMihbXQVXbl4n657XvQ5Amba7nOIa8pjFYMIoimTplfIS
6lCOiGRk/LdXkqTaJiI/ocKGsBFVzz/z/8c4ldXWtPI4dehyLA1bFV7IsZYaE3lzhNEURYVij0JL
3yrW3UT1fMRC52UV5CFpRZJqMvPha+MynxKEryKypt85fgndsrRtGeeRAjZGD9cHkH9A5NKwbfXz
YotHptToojEImV74kb2IWiQLVXTXYwTduklB0l/MGzK8PgRGyu5KPBD1DLLTPRlo9zpp82rgk9GI
w++8MLtrj1b7rNfc/5Jf+xlPv3HF+XECnKEaYH/JKpl2LwhJ+tpMVxJMg/sr8qpXeuFRwH+ujrOU
KIxZNm8hQH76iOrVi0Gdeg64XmXrE+UF7M03JLYOirmDCN3mhiVHzaTYXvOnl0ojKsuLIvmqWhTC
nlYF5SpGo2p0IG6DDW49yvDlFHxG++y1qiWGkrg1OU6WBeZEbo+TvcGrBfLBOUhLSpGfQbVm536i
xAwtEZWfttQ+AqqEinf2LVBWYpz5pPkF2xVm8ipZF9ZEE5nwTLKNNuTJszxtTZaHgjs5SNJC8Bsg
Yv0DuiTysfKu6gZPaFJ4r6n9FsWRRrMlJUOiMh0XH8dN2TWVb2EsisUS7QxiefnOXl74/auHVw8/
641PfuW//6Wv+atIjJ4zAbhtPYB64tvjuhv31dG0x7k3q6RBXg65ceDfZYxCZgpsjGtRJpV7osU5
7jvptEBX0G0iSuBaJXMAoTpuNViYFDfOkuk+jzjEvVQHUwncPnDvCWunxcqUWJxCexhZaFsZNBzl
SeosS/lmOBBh/Sm3Bzyw4jWaYlNUyXccdPy8aeWMHaswWGKEZCccH4Zh9VStR3GVBuRWk6ekoJPv
yCYKp7LQdxUiUGQp6YtsbZFjQ5bXA9tfH0Yzq2iSekJYrJoSkuYngq1HeWlJ8sK9wEpbO7Q1swTd
kIJMp1QeHcQ7WLHuabTfDxTMHJy3+FCny1wHMyNhFIpqPG4GAXE+i79xbYPLFZgoMsPIRYJsQA1Q
AxTvXES1fLFlfbRefc8HHn/rOXYBzmsGILLcAHVjDLnCdMuraeK7mds/rCmVq4POoCZHYs8Hn6Iz
c9Czy2p8AmEoqvO5E1rgnglvQsCX/rR1hr1KiAZEdJK49GMfMlRYMeCw1EKlnucR3j6V7JEj8wLu
78F/0Npg6JVW7BjSdWHV01U2L4EJNAePEID70UBjk9PKSJv7zPDoIRHsX6bzISrTPlK40sBlEZWg
r28JkmviwT/aAzrBXBYRRRCETVYPa+4I8DCb8Pk7tYdcESG51xG6RnkWQGyJCVGqtCQKTYAEy7vJ
mqNHHv+2lndAFBMdNPkFj3oMg4SXUU3X3Vq5JqbU7oqhXH4j8f1zQlvTmZvwF7SvY+ZLiyOSCOyM
xcQ+N4kwVFHJSRXfp90kDrXHXG1ZDJevuOev+6SnLi/OLQk4MwQg9NUS7FmR6VdUP9UQW3AGUC9X
qalFbvQD0lAosHl0RiCokCvAwTVRlPBdSDfSw7qKbhSyci0x4DWfIngo9M98C0d0xQNyGejzUDQq
9jpuMN9VfYyc8XHtz9Ln7Zz53CaAI5OfGNIEN5LASjhbFdGOUwc19PlF1MkicoVSNMhDwjDydi7I
TeT5R7Eho1syyuNeqf3p98RES0iO7LiuZREBiz+R34HOptfP6RpGIA7vXRusu4mCJHIynGZVBtVk
2xJCvocZZdHN/eHOCrK2iPodZO5/94A0hkFcCrYeGA4RJJkxmOPxRlrm4xmEgPAwx0Qf1fecrGz8
KkwA5kGVNA5lb0nCxv7JG0EEBWXa7wrfIDQUZnculvvXL1w/esvr7//yv/81b/oHy2wB3F7zKIqd
fKD2/0GrLM7rPBUcyzzglNVWpBtI2ujOV0BEHJYGh+RneQysYd8/DCQx1ztGcGcKhIMWhYUdfMAs
LQ6qup/AvW2H14h/IK+zqZP3EnaX9m30UDuiRioVy9Xs0gOZs8Pasn5QEKglST1JvBbT9TGh4Ocn
HPGm63MBwsZw2AmR8VkTLKoK0+bDshzX25D7zvEzIwe74gus4h9ow7chyZJ5BanCTdC1tKIbqGr7
7dZr4uveNk5G2yUNPyFVQCQtY6pe072IXA3KKAmZNerCNd4okz0jU4LmwKIuRyTViu+4u57vmATk
tMYFKJD1QWQSKknWAqlU2rZhXo54Fgcwf0yQso/J74WH9kZMokrxNUNO1CPh1eqLrW6+2vILXvfE
0zMBuL0pgOyIy7oyZ9LsxCN3dYOcXFeBmoNc1WGHtw/RCYTKPjvwHoFbBu9eDrRZgPgq2M2q3npx
Dd546plpSx3P5jjdg+gtQ3nx5dc+irywHqQSMj0sUhHKKmc6DgyF26v6zr2AByDzFygmvA70p16Q
E3toMYTksgqBPC8RYG3wRgc5WJn+b9LBFjj8g7tFYJzkTgI9w07UEnkHSBWQ06+iNYpAxBKZ9uop
eQviRa6VYcB9OAGH0Nh6SkR9OC2m73S12GOkvskJZt71d1G1ROhhAQX6FxIMd8HfiS2xU+b2FiB9
6lBpV5wR6eyHorYXR2vnG5B1CRRo6vGMUjvTqa9TrSRG4p+oS9DnbQj1SYPXygFyOLOLIALtDJGk
MWKiNEj6IkpRBf2ebR7/coUtF7j3tk+8+8aZANzaFkCkBIVIoyb3VA5BeT/cRMivGXTvjCGTuFvU
y4wEahHODZh76gX2F36Ryjz55kAqI+EirnDFvqlZGPKCsP6ll7iQju0QIqj64b5hgLiLvlxPDugx
8SqS7Ph2hwCmIC4yfhBEy++2h2TR4oCa6R54E19KpC8o75UNn5cLQVKa9k/y0R6qfliWiQ487K7w
SR66K8AUcKe6RrxHa1mxgxTfw7bVEuY2yu68Z86+bdZFoPa4heMWSAuOv2VxHWBrW7heb04Mtlty
CloR8IQHmCB4KFkYB9uEVrlC/8NWAQIy0StvT6IJ/Np3uNtwSH4bk148Ex4TzUIHotK+kOwfimp5
nGeBDNZ2ngLorAAdyE4epDMiKIo7lQ2myBBXqY8toYOMti0Gs/uXy4PPefW9zz6nkHleaoDHwGQc
YKTyhw3pdFCvSnEvPqv/dcfjiDSkKCpQhhPjzDMq1yKUqojiMgXTVVaFq8Z0POFtYIIQ6v/llRma
6uXSLkxBu+uqmsfKYKPfbTJN/TeB95J5wjj0P1nHPimhSfJh4765s0OEqDBVm+YuKpD6rKPaWUN4
PNNR93voBlvJyUYquGJFKagBStUDxsDr6q6qG3kX32M7dNTMpoFSl/MZGjpeT/ebFethWyKXkliq
8I5kL47YvqnUAxVVatstgXp3t/8uGZJ2PsCJdFT5q28azfVoDHVGRfjMFO/QMPMKGx8+2lvkYTkz
FexB7PIQDS/7GLyIiTieVQhohovwmqvGg6tGGyMFrtOkoi4qkyii0SBPoA9WM9VwYNdazewCsMXs
4hPuXr56IgC3FgCA+j8U8LsHal0dEiicrZtqxOTqaQtifSOGq7Njhio4pzf97ohB8CCOV56fe2nS
HdU+dob/Q22WBFkGim7uJ3ef+2Ab+ssG7VMzsKxrfpqUoRBTKld5PO8KSNtkiwebw0JHAvrwnQeK
2IKZB8WygnuBJevfRMRnJKBkxTNMQkGIBDl6PeIInWmUYacWl4G+IseBZ8wnEVmKkPepDcNAih1C
Gmao66gbQu/ZQ4c4C/uNAnDcBvEgkjW6Ln7mgiFKb1suQPVFbiL/Q/TLnNQmVQhOcJGkjSRa9kFf
jyBES+1d4DbnVar+vBg9FD2T2G7FyXZlWrelRLhu6lLNjk4rLaqAwSfDLN11RXkgrbnI5xEzUzdb
DLA7bk/+zFddfuFMAG4tAhBBW532dtOp5uQ9CNZWVTQNKsP5gioSHBpIZsfZgRpIRFIX0rUYevEi
aU3AUEUKeeDOENIY4dBv/U3fv83bi+QBCfTKYRbJyugDFC1cVIN/I8laxmcGBI7lCtA29b8i1GmU
BLBQkNcVYxq4dOVkMO41UyKXCVkyXWyk0RVtCu/huKJQRRFsQINvVtBax3TX+f4WtJXYgahBa5l2
kxMAfQa+F5wtquLVVLb9clbdeih34jW4gNEuGTKzlJRBm9dpjJRXYcutnUDtib13MKyzYnzI82ZU
DsU6RIriN7qfpvTdnkGVbKEjJ1a8MVFmu2wveLznXik8nAoU5LiCnw9+dzn+xeJ2+Qn3ljkDcKvj
vwW51NSPLIBw7MBq+xhoGc45y0WVEEiVr3SYmfnNy2LKkzvJFRl/FPfwtV6An3G6O4kcJZeYusVp
BW2Y1efJTEVQbka7We4o830KpB9OAQI7T7NC0pU+tgDT11UDiUCtKEVy1CEHyJOfw3AfISQhN0Zl
x6tnMcE5ICc7zf9QhQ4HMXdQpFxpe2LkzOyHsPjIscMBXBJKIZwd2x+u852/zz7Gg7C2btNYmXKN
75t4pFjRcgVArRCzlTRAULxbyAPQQ7ZqFZCKQ5Ujwq7EtJfVp5T+2TMpVSTmcvfdNMSr7KfYWPIT
r4P8zMWXp+5cPDsTgFvbA4gkMh4mVI0by+pwjtOuAguCiGmYhaw3l2z3BDFVpUVu/iwYkjTDhd0y
E+UWI+eRS+2Ew15JxMV/Uvc9sXFJi4JrtBOytV7BthHmwOkJ3xFSPypfaCipGkbi4bjyF42qNUTe
A3RyFmf98xs6McuywCzvq0OvA2TCeR3VhVXSrIJVMbiuUEPulIYe0IeTD06Eo/IwpolMtF5XCSgn
BMhTZVvXiDTPEGWMkZWsEBWfqm2dcD/cFGKvVtiGiYEXt42S6pK6kpUCR8kbS4JCsvObV9jEiYDA
22DYS0oHwlgRdUFusviNYrnqfaPym9SzwPEDXLjfffVTy1vOKWSe1RBgg9XgOpAUtMU7xZa1XnyH
pvoQVCIWNHZG3gbCLPDeA7WuOOPR7lSZbpPlsb8qfd3t67bJo+pFWtrOfvtaDgcpsdiC0EKBImOa
eu+W49csZsSc1oLRcvxZC+dgi7mth+Et/mmuk7rO2T22KnwleDm8pu0zBvjQlz5ctCV1xUwCcyD0
PX0oMuPBsfjS6aNBWwGA+XLBNcrxbC3HKoylcj2z+DpRr3pWPzw4v6WdG8PSxVKKbQ4G7mEoRk2P
1+VmZheH9bDjszsCnoevXoggh88DonSxBiBIdX4Myc4EPp43z7atnZYxLX1NjKtBLEnTQkM/tL7Z
kvXWGaIGh4ewsZ0pGWbcTuYi/9R+5PYtPAJIzDa+vWvWp97bCrIv4mjyfdOzKgu5K787UEEt5+eG
wWxEodNR6KdEeAWCFGXZqE2em6YXxRd3MBFyj7FtMlgtG90TXqKYDERMKZl2Gt4O59PDGUREUeGJ
AByrrTMBuOVZACxPqUqRWwyreKRetfBztg2DOKTmpY8ZZ/DXV2broQfpYVBrtN9rhoEYDTlb0SqP
qQpSscufV9frA9lLnESmH5DgRE/qo0Pq4dRvk1yH9wKQGP7KCW3Czp0yNncTB8ergnkHXe9vKcLT
Nk3iRkmgPmWCEWCIhnvgJ3DxnCR7Kl/s2oIBSqAaWFW/3vX+JinK3QqP9tiB3XsFEfOrrtnk/Cga
DNmU0GMIDfMYQMGlWGA/s0rYVJekKGikPYhtVXMbbqPoyclA/1r5GWGTpNxC2ZAvX8wvLg7Zx4qB
H0RDedpqr/FnCtTTkUYyDmxyklcgEU4vf1/zhWwUpXVp78mREzGPC3qA2u+A27glRqpoLaeKFe0B
b8QgpWRbnDgr1PysEgDhGsdANZOdoKxcHSsUPqXraggvpYiQMBybsgbuyXU5Yr+4a3bnMlDGmtkQ
hQ9BHJV/0xe3r7dYpqslCtBeUcgxT4kIQtbAzIlx8KaURCipmUPFGCoKZqgTIRWPYrORkAWylhWA
WbqT6jA6I13BpGeFzD1gOyizpUFTV3+LdDYRrj9wvpsnPQM35QLUlS4bsgdGMR33IikLFVQFzHrx
uysaXysCnSYacvraS8pMfwVgYEWqnib9LSQVTr+ft0Y06QiU2XWumvyMW55IHx0JJgCLCphyTyhh
8aNPsnU1w/WxmLg2W5jqumhfBAItj9J7Zrnw4HuBzCqE47W0H73md7e3cGIy7ERExgnGmjakHLn4
GM1hxOqma65oEumFH2orycijhH6TbupMAG5JBnDEbb0oZpWFziULbEGTM/liBY6hz87kdpwfaIGq
v2g4ZrgOmL36U8x+9tvNXv+ZZq9+s9krXv1Rf8wX8+ebnF//KH/+x+Jnjr7XP4p7c+paPtp7+ZN5
Xi/29+x9v/8UX9dP9vr9o/xdN/n8/lFc14u9Jv9J/mz/KXwGZUL5Yz9g/hM/aPaD/9Tw9/6S2fe/
y/zeA8N6rf6NuREk/ru2GwhaH83qMWpTIQOKBiHfSHhIwFWlrzN6LyqiRKhHiZwQ70tr3y5+QERc
tUj6nIVmc5Hfxb365NVGzkwAbiH8r5mqp3FqSOXZ2aN0WlwP/WE1zBengS4klFy2+Fqz9ML88UOz
J58x+0X/e7PP+0qziztml3ft7ISlp02b9rG3V7/Z7Nk3mf2Mn2v+83612T/7VrO/8Z+af98/Mrv3
pPn1tSIMZeDmwUbPaOkg2DNimtoA3AotYR+i9g1tPG4tRfGmih+javFuzhrBR2MPmWHa9J0Wq+RP
Z6YGeH4zANLTsgQWdZY4hdU5eIPh5u1QrgTNuurdK8HE8QAud8ye/wmzT/18s1/8m8ze/NmHwG/7
MPK0adOmjd3bEdO+uGP21CvMPveXmb32U83++z9m9s5vNrv3QNg5geOwoHSj1gDXexnhYoMFm47A
cG4Jsny19VybHLLsXSv739F79n2pOHxYMG2WI41NpZAp2CG07n3kBX040+q2iMQUO78uwBkmAEgZ
o85/QORagdzn06BuaWIuQmTcPtgm5e2F58ze8Flmb//NZp/2+Yd/XK/NlqV/90QBpk2b9lG5ub7x
Yp/0FrNf9bsPwf8f/g/HzZeLvOfuul0AcCD2tLKYuL1kZRJp2FO2oBqPiNH2BQSd0JGatW3emOfB
Yi+uLbcqMtWyB+TCaGAaIC2RQPNe/Vxgj+b55WnLWb4X7Zj1ie08yTFm/xI2atbT5gEe7mtVU3Cv
fP0x+H/eYbhlvTZbLsxuQAs6bdq0aaeRgKUp/NlrPtXsl/82s1d/SoO02wzAUVERgcti64tHAa0h
RXKSbe6SwUJfXKCvUfAnUQwFRtFGuRLWhPna4r7MhjYIKkHkZeA9aASEwFS8KscVDImOZgJw64I/
iXB51JpkiTkvp0gzp/UIdKqwBzd8+ANmX/ArzT7jC3sK23bEp02bNu2nMBE49CgPQ8Zf+X813H3S
7PpRC/yJdDPu6pLz3KX5FZ5gV4a/HZbFToSWtdO5VQBRULS4T6rJR+m32UsrlXf/skhixdwGa0aN
RRbx/Gq3M0MAeFUqs+LvYEcl5MP82DEZcGa5bz9zPfzHJ7ze7K1ffAj6WGfwnzZt2k8DGrCave3L
Di3HizuHVUHb/JXXmuTGImpeEvsIOsCeEaZCaxzYx6G6/c7kcVGtnHoSx4rJSrpiTxcyXo8t10tr
GuZznNhazu09UCjLgog5P9wgOOEd0hpDPbDdcw077MZ+zpebPfOJc8hv2rRpP40OcDFbr80/+x1m
Tz5tdvWow+BuxKrI/CSZt8EpyHoZfIUsW2WIBwQInQZ8lV/GlBdCEuZh8C9A/9HvNnZtqCpo1kVB
SGdcEoQUJkgTZV/9bSYAt8BUTjcltQ0jQp1d2n7c7xkjZGIVUYP8k99idveJLEM3bdq0aR9Tj35h
9oa3mN25f5g78uWkU2MiLMMOE2YjFURjT3XP1Vec7tcWgAUmQjv24DuleK/bqEjjqp+Cu04quCpH
QrUisGmqDGWB+0dJsd79LFGA89sC8AE1h/DfGh08RYV4grT/OA9qffHYmcn64dOv7i/ejP/Tpk37
6bRnP6UnAOZhuFnZDrcJ+MTtj1rCyLnkljyC0dGwFm3eS00UjJbkl3Fq3a4axgv6xeK74VSs5euN
s9ud5dRTvqQskRMBuI0AQFIMi4eHm0IQ5j9I38k3JinizvYgS6YZ6PEHrqvZa950/MHrzACmTZv2
0+sE7z9ldnF58EXWoWu0ITcYVkgRFIN/GI+jaSr0wboobVghB36Ukg69+x67B8S+rLDJMr7e6XrT
/0vIgnYlogi4CprzcKEfBxoRc4UzZQI6Pypgzipjb4rZnkgoxktBEFUSDD9EXo1OJ4mzPCTTpk17
GbtFUTo7+qbFy+q6cQF4XyMU5cWolZFa/7DYZS/dtIgBqaJqC+ZlkhDdvbIajkh7KgBf1EctKrtn
6eFztLNDAFjFC8hajyigrUoAgk93z3hXeVEYFIvdhWnTpk27HX4RtGrX/w6lqll0ZOizU9DtvLRM
dRyYc4w0FunvYoFG1+Uh6EP3+IIMdec32OYGuqog9itFK6iB+T/CVsTUAngZIADO4ydFP0vhKdKX
Dl8hqmKQLpJF+gmAZm1mBjBt2rSXvhZK6otNCRBZulgG60rd6sadeqRJN2vKuJIRoB67Akk5u8nw
HWsDoPDXLO+99ei3X8g+Olf8OaBvvAObCrFXeQGiEuf52pkhAMjEDSiyyOPDBjiLBCXLiHMlqmUd
QC5vmtaT3XfatGm3yyW24NeicpZ2jgGU/5G5VZoaKg7kQyDynBRJhU3diZlv0wZw6umbJCDuvXN/
DPX964lhOBb6rfJvDIC0Fcbogtfy1b2QjGXeeTr380oAjg8WbR1QSCI5ZqtutisC5pRCg0g0EGWz
RmRD06ZNm/ZSukKZhCe4Pyjx5ao/eDNXMD8iqO5cHIEShTFv/mGgD2XlrgWZUwFGQweEziayIpoh
aIiDxdE/4gsMCYiFpKAnDH6WiMB5UQFXR8J9Zx+fGlvbnwErGCtDhlkoymOdXmfatGm3JAOofKCi
AbIjX5UwhIpKXgAm9tGVv+YvSUuAp/g5UJfXRkFeCjfxvqHNO6Tp9TTQOERIkG/dx0NRd5YtAGad
jksfHSFCkTxUGUVPNd09wE1xQwQTCpg2bdqtKIdK7vydwWhgmwwYMwVW9VPylbb/vXu79NtUvm86
Bl5lNNvHQPbjlZBP/RM650AYKkwfEec7D3BeVMDDpGBvGtQ5xqf0L7JN5XWSThA0bdq0abck/qv/
E2lghJkmK+D6Hnzd8wJdY0El9EAK8TBUKDS7HGjZP28XhbqpijDPBYYnvPbZHngM4n6/ew4e2Ikn
kwnwlp/5baI0c1TEx8qywCRdDaKxbGsqThlnXgs5DA0uZykXOW3atJdjNeTC9peiKGkC6Ncpb4pK
+/a1afehB7a+l2+FkirB+MhyQ4d56l5stZ/IEr/gZMHiykP4PTUHgG0zCtvAeCIaGhSWkwjoNp/5
/iBz2Fee6P7gacCPDljYaAkqg+OjP3sA06ZNuw3VUIv1UE4/MzdfYXCXcBnnm2FxkO9Iq7t4a3f6
EletOcAX/pAFfqL/3Hxw1ORFp2Tf5g8cKkjkcItTYCNyIgOXcj0R2YK/R5SC1sknFfBtPvPHQby4
se9V9uYm0y0ekkgVuUDdz2oTqd53U2f8nzZt2i3JAPK4srfhudjabGg8Uei23Xuu0VfEqkhj/HGQ
GpJWwJiWOJbYHn3zMeA7LI0qctrCZGzbZ+pBngo7HH5HpxSmlGj7i7iRIPzvdpabAGemBkgdHwTK
Xg9V/Fb509GCdcYrWiWtgCBhla5+57Rp06a9dK7QywCdiyEmCaKVN1LL9epns88DBv8eOfd6oObg
jBWB9z9Q+jq3+rmPz2UbMRZSquNh+0Elf9167EfnSqiKx+KzzQTgVqYAg0OIPjna+/v930SukoQj
NqrJLgwUtbFcWQfnHMC0adNe6vofOKwmhzW5ktRGpvwSs05R8hz9JQiuh5XU6xYLLA6unnfxNxG2
RvEbefqTFiv/dy8A3cP1OPELUM7gkWZYb2LXLBh9sJkA3K7g3zWkkY6f90k/C9KBdMQRDqfSWXai
oJ41b3+cQ4DTpk27Lb7Qo7A9+T7ez998Yf9SVgXUKTtA2fbgtJK3zU/RBkChqivVd/+jBlkXpj4X
/9zTANX4E7QgJkMWSN6QExJUSIbzBAHs3BQBLs/u4Bc7nRvsA8NOgb6JSBwHXQCL6n8iB2y1mlYa
ppk2bdq0l9Yp9gq39bqrATcK09J7J9FzWQvY0E/aDogV/RE+lcE/ThCAgJpSa6LNBtCaIVRESPGB
44SA8//qWiJTCMbf6p4pgMD/z6QCfnlAX32dz2XYwyNqBMjDhcgDe5ojaOyUgPU2VR8iNLMZ/KdN
m3ZbnGH/X6a880wOVA7shwE+ht6H7H4E6zuV5PFrU3Ji8QLCfj9D+jKXFRe9IcUfEMSJB7wwnvET
24YQXaq/2QK4vec9neBiIYQhrhC13Wpe6uqd6tSXHqSjZwowbdq0l7rqH4eq1lv34+aUq39kQlO3
TqUuHPltsGotizCra3r6d6YZrgeoE7Eqqf+oGJAGZhFzMyPs36xihhnHkuM1+g1u6kwAbsm531ZB
/CbUTq6EEqvVOhgWoaiKLXqyAEybNu0WVf/uRSD29P9u/3Vz31XMxwPKMrwiVkzDUJuLs8J3HzkH
ZIjRNRnQrS311adq9+EGF28nnOExObMhQB/lnDqYEiGvVsF7EhSKg31Md+lBAWvW/tOmTbsdCcB4
dl391kAdkL+zDTx7QhFcpu6wS5YD8akkn+5efo8u+WHX08c4AHbwQnAQJxv2YsnxGjG4qTMBuG1n
Puz/C8e0VXiSHH53jBn/2mE3Wg1xyZ9hcwtw2rRpt6Eaijx46MUPQs3vlZuEcu4HTxs1Uoz361mu
F4jb+uKfuaXqQs4WAj9C/KV97Izw9ySEC7/YxUcs9FLr4ngP3JVwaCYAtxUBULIfp+SPFYGVTcqj
RIRtLYEymeAhmOPBPxySpV4lmTZt2rSXGA1IXLjy7yDSn46DbpV6C5wIX2+EmkbiNVNZ4EMlDUJf
u+qf1Ptp1q7QKShogGLyI5B9kz8OZZuHeQAPW18QNuJiKOHlb2e2BqgCP+1vdEtEtwHa1P8W2L1l
o41vOsJaYa3FzQzrerZZ4rRp016ukV935jfSM/FdRlTmFNA9IqhOvlD+yVNgbj/7uDHlR9ShtR+2
wgmW2wg0lyXrikmiOPzesOLX5wIgeUUEedW/d76DjppY65Scm3e/PMcD37F4DKY/4o6/tgHk60DQ
v1H2Gn+aqFRNmzZt2kvpCpHqImYsReMC8L5fbxT0uBqmwgnMKihJhIZk5dYv+ITBu/0oijijhKQn
LsAqgV6Sg+B/Q91XCR6bEzeCtZCx/d3SuGMc5+ncL8/vzB+keREWW5tIZTu09fgI0kvAayVHTUFX
BazDn1Y6qNOmTZt2G+ohBL9EdLhtR39b99Pv6z8G7d9devauEurNL65dRKhoOWwFk/P3ciaREFpi
APS+z8/9+TaDBf5qU6G2UO51XqHte/v3MALATIIzAbjFtgXpdCAZWdr2WV0Zpehfxy+TH1+WQZ9/
Bv5p06bdGme4yZ1Dy+EtcG/COa1DHiB25urf6p3eUg1Dc1IUCT86hWcjYp2iWBINdq3yBdI3bisE
/8saL5RggBgJHTy4uH1GEJ17VlFE/GxnYufHBBixH3RYp6FRx6z0sKvKBxSio80vjApmFL+zpBGa
Nm3atJfCEcJiP91QFSsYJw8FP161ot9/X/wxNInPcV2j+bGSpwkCuGFV/9wmGfhnsYRxuA60AG9B
BZDQj/DZuR0BV/z4XGe7zmwNkIdcQTkA+gOk6dB2IEImKoxVtErQZQD8eEBY9MKbYuC0adOm3QaH
2MV+EIJ3oMhtVLn8pah+oLQ+hXRtQLNroShD6tU7Vdpo/roNLyKs63EC4cWQVxBBArLIL0TrpcsI
613RpcGZALwcDrw8VqRsV86ejzLmriVwkwcvtJHT7UybNu0WFEPdzaH2eUTH2+l5e1+/66Ug0J1n
ZrzIwcJQ6iFmV7z9lGZEdF20Vuj3Ad23bz6a1vykuAuzWnkWAQEyJlVAsFrsaIxwJgC3z8LQCUNF
w2/wvdeHf0pPFhxh5Q+WBg+nTZs27SV3h+aCaQcJE5Ne6V6cG03BVUN2aWWvctF5CIAr/67u9+KI
is1gtiyKGsTUo5Ippk0AS6Xj+PO8nO38hgCLkB1r83KUI072H8kkHDd5yfaIKadNmzbtpQj8+z6L
kcseJFcSAKJAHoKzVz7QC5/atgwg/X+WAh6Rr/IHadfnHlYLg4+WlT7s4iPedhtDbJDPfp4qgGeL
AGy9nQ0m2uCcvr4aDxySTvXGJFXRAiOoTkl/yuYEwLRp026NNzwW/xBKXQ9zT03YDyBmv0Gl79nf
Rtl0px/q7uX+vQwnlnuAleAQ+fg2m2VjVMJDywL5ZylhnIdkwrJwrM8tgFue+foxWz0G+zacp08e
rJbF/+tOGWo/CJ30oicX/cuhP34CAdOmTXvJneFWycZIJpv1rUPgvvQCyQutU5nq78jBhpbqTw4U
wd4LssbRhjhkB5rdg/rqiAa0VW4d1ZNqfkXDgA9fSsOO5OCxl+CkXOG8nPvZDQE2aGcQjXXHteDE
3vb9o/6UcApAXio3Yh2cMMC0adNe+kqI2vqd358n7mTSH3Yg8LG1zf55ElE5oqnLojK5gSq90++6
zNg5nJT6rG9NERdLFPHpAd+O7QTIJtcgBPRbICgB2s/g3ENc+6rFHFMkv9hJhJkAvEQZQAzeLGQR
IRyZdm09KpdWgehcb7CWtIZgtZDFtGnTpr10xVD8S9CeFCQ627H1aa1l2qfu0Srt6BCdxgV6K7X/
WdsLXZUQ7DONVwM3/7qkK+df6pyQWGhnxMLNN74Ab+vaEsypcHOP4nCueMmZ+fblHE8+b5BgC+Ze
SVHSqp8f82QgHrfhGsm2MNvSDthh+vRD7zv++zId0bRp0356S/+PfMjs+sps8QIWiBDB5srQ2fJc
t57in8FS6pRE7KoCNt1eT0mCmZsvQRAokvSwKuBNJ/E3VcCG+mrZn0cPoJwxPCS5feQzQ3eXs3wB
tgkA14fOiWqToqRsoQlDhLmB7etURrgzSjW16OUgVmHvfbfZumb4YNq0adM+1qX/+77P7PELBr84
wvrd+/VqdhO8WYkUx5TMZ0jw0+V2QV/jG4pg+u2tWl/RCqxeaR/+t0HvkdWvJRkoQY4twMvQt+YA
us5foBhB88hy2ziVhDMBuN2oV6SEcIF7nL8Eo0PHgydEOkFAmhBobOsui5v98D83e/S8SaNp2rRp
03467Lv/rtmjD5tfXNL0O0ItvbnDDnFzoSN9U/KNDS0Xel1eqEIfG6C8Yiv++TvcdHhQNQs4CQkt
COsc/078/p44A3R4kGcL86o/Ah2Qt3vnrBmAOQR4i2v/YzYpCSsaaxSI7a+P+UFPKGe57dQ4MQv2
fVghq2pTpovhO77F7NHDvpM6bdq0aR9rW6/Nrh4b/rf/xvDhnzDcuRsUSsLK3tbudOXZb2VzcrAe
qHH6/20CQ4EyrSuyF0RpoDXBRk6EzuMf9viCMp82JBB/IUnBd10AlyXDnuNAfb6R0iBDB1MM6GWU
DLgVoxyeV//o7+JaqdtIpxrDXwqY2Y/9gNnf+0tmj49JwHo9ndO0adM+NgYcoP7lwuzb/8oBgVzX
g3t3b7MAyBVTimcimmMj5jv0obrqZ9J/t9U5mi1I4AI01g9J2grvi3xp+afwqELSDsi/NWwdJqRg
JgC3903Yzpqen2Ldw1NIr/n88/HYDvGadKJbf+vuE4a//efM/tm3HQYBfZlJwLRp0z4GLm89/J8v
hve8y+yv/akDOnnnXoCref/9GJMbW0oR4zAOwFUWcYoi14toyomG9zxBfKmoBFoQaiv+vsogfLtP
tlrEeGNqMdomaB9iDgG+fJJipZruvXpNQZECuQZ/FOdqJA1M6ymPnjf7W3/a7J9+6zELvzgkAXuK
WdOmTZt2o4ofB3/iy8G3/NA/M/tv/59mP/hPDhsA8WstIprWlP/ycBxOBv8+YF1V4JD2ux/9JbD2
bWsfV9conXn/xUkzqHULMPge/hVR2tdPJCt7EMfL3y7P683wdiidmzxHwolGWJGmPjeUAEROodkm
0wK3/VkZWCFuAIP5vQeG97zT/H/8E4dWwGd+kdnd+zl7nzZt2rQbuzhuY14cfM+7/6HZX/9T5v/k
fzZ74oHhiDZ61OvjwTrhyu8MqOr4aIK/DPTNcXamQKxmOLKxCpd+/G/6dZFut/0sHr5GG/w7/HMp
4N7mCJpsO1ZzeFsJNCYtcj+wBdLg4Db0l4rCMy3aziwBAAVs7yRTjQ3L2yGCZfIIHL/Bw796UhgM
jYHAXuVmhqsXzJ58xuxH3234y/9vs/e+2/yzf4nZ08+a3b13eHknT8C0adM+Gnv0EbMXnjf7J3/b
7L//98x+7AcMTzxtvl4FlXOl7O1BzrrmiWWefJ7ulyTAfZ9/n6jY43+beFCQZoD6Tkl2oIJFjasA
h+FFoSQm/95IhYziQPTlEEoi+ngbXXHfAjjXge7Lc3w3POlAlwlo6u/7MK04ZrODpLPxCMhL5+bX
V4bLe2Yf+ZD5X/sPzb7tzxs+9yvM3/w2s2debfaaT/sYJEB7yoRTtXDatI/d+/XT8Lufe7/Zj3yP
2Q/9U8O7vtnsu/+B+eU9w50nzNfrI/oOIu8ZQ9wdEUWq06PHMOLvLyFyp8wCppoqW5j1PpnvpNoX
kVnd0yt8OxMTJTlha/BvS3TQAztCWzgzw/J8uDeCpHMTATrrBIAP97Y6srFUsSpgh5TopAhs5ZRF
Mte/d4pM8/5PnJHyC4TVcO8ps8cPzf/uf2P2d/+iwZamypXVB01eBlT5hiJw+iKF5AchMWIorV3k
ioxk+J7fQ2D14r5K+DwoJjOj8qINZJr5lx5pmkW3ezn2F23N8GFjb+rOIK8RmTJCStVSu/+eELo6
q1FsoNYQwnOgYqU50SRJSvcxnjN+9oboFPvXwagiKqrDlBnzrxeoOFzLjcMXuuNn5xzOBNLbx7e2
r2k5BTp+ftU11dd5fNZ0ToFwb0lzpgXW8JC3d47JdFQ2JFS2/PPL94JL8Cyy0/rpW1V8eff4XNdW
1PIcv7Nqnrv4CK7sq1c8/k4V66v9jDcIPSQSqcXQWfdE3KesW8J5X9cO6ZfvykbZ1n02+7x8Hvp7
7Okd9pvsf80E4DaiAECf9JSzcYyc6YCLE0+6VqQK6Cm5cAqsXjgaJxYKrKu5Xct8gle7JzxbMMjY
0xxD+bVHfoSjc/DoaIGQKFgOjhyczE9WRF6k1S0JGzjnURIAi8GNHPe1MnhBggXdg0Y9DnFglZTp
qGvZ7zNCleHtGrvwiZUpW7u22G8l518lauzsqoTQY0BhydRN5tRNxWBcoVD5iSy4UkYGkKa8S3Kt
9RiOQYF+l2PIqe4hUfHQq26hDcfrRzw36Ou4hlKba0vw+u3yLpPrRc6JKGvL14MW+PTsdq17rMd3
T5ILD8FXTxkn4YCeokZM40ueeIdpHzy80G6qpGchiEryj65+ut0nNy4UVgnuXYmVT8bxv1ZqCxS/
0/VtVx+SkFwvq3cGD9x4yDsSEOVnxYmltfYxXeeLTHhnAvCSVf48VIJ6t9R7YEsPFMEDHDWytxio
laP1AF1mmMWR8cX84kLfWAQdbeTKsYqYXhbKIFd5PNZHmk1fPAXozUH54mUi4Kv+Ik9VsyWeTSC9
q1JVo/z9PRGCq0OWYSKvVDu7s9FnXldrGqiP/U93uv8oYFBQYbg5iG3AiAuPHuiwJRwBXTigoU57
yUzC0n8noxJOQV3uI7bEzvarJ2eQhhGMiPhQNbT92+JyjT3hgVZ7IZNz+r0RuSgRgOrMw8rktA9v
sT68JYn50mm3+0iJTkJPKJVsTF8Ytg6BgArRSfRFkcPKaYE+nFtmnGsBGXzioQHdYEXMzwiLVOMe
NpOQqnyPB7OqvEPREZM5EPrlBUpbJSO2roqGJSEjZGCqKCSEcbC7kWPee7wG6E1j+fdz3tq6PLfo
zy9EzvV6ts7ZKueAHqKvE68lw2cK7Xl58BowGTJJhqSPyF0HMDkYrfrC+sgpMhTJrQ6QA4oHmaKo
u/eXbbflCentNdg9OACP3xegtbiO1IVAQA43OGauNE19nltndvRWjao0I3iiWWnAGie6uRuu134f
zcKQ0fbBVgoYKgPdCzyQs16PJ2GloA4hGGurTKhYKFA9tv6s1o3NrXBUK9olS0JzTGAYlrfVDA6B
hlv1wwjEeh3O2hGRWWEJmoLe+w77akLSnW3d/hH67tYGhvx+I3RM0B2uNDcwa6UEMyFv7eZR6wOE
8OXEkn/wFv7lVmDcNnFGXVqQDs+bWhAwDbBbotlbGGtDQXyAaKTKlip+86qo6v4PnsErMxzf49B+
agp/nIRAq/tRf909+FSXZ1g9M08InPdri35va0EWCdN2pgRFtCkHfLvjfyK66EoADF5HAA8FVLgF
Y3SS65BoaLEgfcutwqh6zu3AEQ0GBWJv7QIrqDdT67ft8ba+HpRjW2tYa6swFoZuwIMvfnR4XA20
LN0ETvSi7WKJjhu7/AdAxTrW7wVYOQxFweOBo0OiBc8kQaeOi+lend3I8wIKtNQQZPusLmmgMb+4
CdNp0T7JHqkjFiE5EErqRsxiSsNa/aaokuJEq0IBns87inulcwYxCOjv8qTF2p504nrXe6q3fEMj
RoO8omxXvAvunvRv4go8mBpW2m4Q2lC5N+4JxKvadf0cITCQQjJ8D2+EzgFYp7gFJUUhqIEkfc0C
219SxYMo6LXgLT6mf95IyNOOQ0CdEsB6fDZJd6CYLah9zGBeIMmvgNoOMKsEg0DnDUQbH8+P+9m1
AM5yD+2mWRpuAu24voDlGQvLrLxHmq4JRXAsfh+/XF3QY3R9KHtlECezdkTDQ3MEGXZ1jGrQ4JEH
60Oc7cuXYc33vb1wlKCY7VMyIsfc3QPR4GHsPJteRco8h/gG1MlLQ4gYSldMqYicgmgA/HwCJGkj
MbOQxOyOchN/ezGvklWvfdBV8PoYuofE4tjy99FjQaGyNiBzKR42Iz6Ho7WeQAf5eVlPlCwkj15m
SekhYBdv78n+vp9xJi2h3+aFjzHxMYbA7c/QYCI8q9ul6mMQSHMQboiXGWR7iowmeOEzEHwGtFWC
lGEjH8w4wCyuqJ+nHvD7szu6QBmaHfeZji1RKPo2EYCXi3nVu0bhG71elYH2lsqKzD3pDkY/m/Sv
pSLc6d0W0Rew8ToKsJ8CDZgL2xyDVL29o94ZtqoKHrv3v3SQniNC1BuP4aGjJfH5gao230POE8Ts
XPp9FCllc1nVxL8XY2ekHJljc4UwhNC4ea+iCkHGeaQibrB1rMjW0U439UtdX6RMn23S8wXqLO1A
V48cPwZ/lNcmyHhwG2OYzDsJ37ppQjWQl02vuNXbKZ7x73HONcorrM9I5Dvs6T0CoT35vUeBqlRA
D8Z+IwrnlAN22HnvQec0PntIouXhzIivALRftfdOBr2X8QPgAVX199nH1M8PZ6rsen5aAC/iK260
24mcxVYvM79IcF216YLESAm1DTpLXdoyJCIFaUf0YJDfGy8fOtkv15QrOH8x99gH8dA0kSorSB7O
81NJEZKMpydZTy+DhQ+cc4wEzskd9TE9AT8bLOphKKpjyj4AbDSqxRYT9VCLdTlpc8SvG+md5DB2
kvJ99CP3oBZJAiL6LhuFdfIdZVxHCZaOfOr73NtjMjSQVuCK/LyAkE8l17KLK8HMT/qZrTKOXP0Y
DPkSYmZL8DOu98htl9dWrm1LLBHzZ+S+oyQkPEzd209pMNT4mjRJGwPrXqIlGNZ7XjAFFoORrHiI
KomhwSUZTpxbALc/BQhQXz5KfZTGyt3hYxB1aHymP/A6W7XStgUzZaUyXVGhlUJ6F1KVu/Wi4NyD
9QxZnahm2zUZJAoxMxbzGhivE/EQFWjXOE5Fg4fOaSK4OawoyNkHs7ruNop2YBy+6pHZHdlrebgv
rvB6dZ9ALYCuj15Xs15U9+42ngsQPxwn7z1B6Nuv9dAnZzh5VOzIQF088YGbIX08aU3sh3kNOB7W
1mCAFzv/LpKq/UwEGNbrlhLiM4AGf97JH21xxIlz2WZBdR+V48aPKngN/Ga52gHNuN43+vzb4Kbb
8Ew6onQOym0kXeAAUeGi8AOBW2R7R2g2AGGITgYZinFnHppGGOzzgZqfI2znkI9p7SPKmpVnICT+
aT4oDM6GeSw3XXEuV7hj7/8MlwHOKgHw4nwKD4ZlWgeUtU61g+q8OzJwiBsKFqb+aeXLwc5Ne2up
H5qmYAOU61bu1nN/0HX8voacZSpY4Thvn5lfSiJC2naS7Tj9DN2N7gl3HbKcPwtP71dBgDxxXzni
pIyf29qHoaxe50nQruv+Bqj6iSty/XpclKUP0PpOBcvPMcKy3J/edqxXJXJCe7am9wpWhn6T+qz6
nbqOmCEcT0lHDByysy+7+hHkohmL0JYbYdfgVhz0PXcLAT0O2rZgts1myBhfq17jaeDJb+E4QLh+
p42TODcyxM3CaqecSxphT7o9+rMRKHIFWYErkhSq29iGcU1L6LmFBJqbVltyt20xOScBGfJBSNZM
yNlcxdn4HEHXBw8rrJCtKSeM1T2soIiPKci14tqve+YtCQnjbAHc4hSAkz8vh3aQXsfuKHRADbFa
QRzUGUHIvbKGRalhjBb4CRKlCWyjyl9eXq1Q2PlV0+ttLAEEcYXBI7ATW0LQC1UXnDPjjZiF4UTe
vSjAVHJ6SPBdeHauVX+F8qR2tQdWNt9JGFMV7VRpcfBBQn5BzxVxLHwHpcJ4tozgTG/tCIF6vW4H
FS176nL2YMh99YOs9TpOi/gsRfiV9slb5W9rhp7TVoDz1Mn4TeKVr23FlO6DTG7H/0X/3HyOtWXu
w/dQGS+3y1vkPeXfjxMNMg3e3C6JvXL0e3rCx3A7jZNVhBZZtWWidAubHgDCPBzUs3rgAkAc6QFt
GuXvd1qLRnie8nsQ/UwoSMjHWNjk0tZFgTrYKHHS5PiARBR+5swogc9yBsCZ1MW3TB+hY3jijQ38
zz7seEbIiJkFVYBDGOjEMdMmOytWUca6/dl5oKmC/aWKREoUuE8N5J6syQvsPFebIGtH7j+jWE8r
b2+VBDFk6cFTDSVDTww2tc+KfdQo9GS7hGkeFua2kQzbyeAy9nuvO6tF4IBCu+G9/xvWIMPwt/b8
FWJXh+2dpYbOJ6q7S+uAKB8Jd2Fp5NrzU8u7Icq1kRIMQFdYS1TJdM3tmES2YrpqnSg1qJWL5dB3
m7+0BTD3dFyzo4DFFT9DMbdQIJIoIlk8b8zLwLNAw025Ypq+DX2Knyl+CCiURvVgQgfae8dZF593
oE6AJdcgFlVpkyIny7HZmweg6LqhWXPBR3CeY39nnADA9GXv06euvTJa/9FE3xM8VY4mUw/LE+2d
k8OGMlD1fS+BZBlibYefnR0pU0klfoSEYbmHqM4ZadWPxxrk+12n7mUtCRbWmlxXnShjRnA2DMVx
n69f7FG6M0YemO7Ol9zcrg6p0BdNKmMpuSN2CNeAEX2gji1xksQKkj7OSwbDknJ5seJA2NVHNZ1u
kviOMleI6AoH6nq+wCX5QA5MBIX34s0t9q2NWhF89lEFdalm2am7tMZ0LgICjYM6HBGxsXhWRi6f
kiXQEC2IPCBW8QmmdwQJDdckfXzDO5IZrgfQEgI87LgiJTx8nyVIRzfByAlyqzEhh57fV34vNuQA
ccW3GFjm5Ldan2QmzsNGSYGeeGBm5HZqVdABMhxtYXi7TMLOyM56BsB39P2S4kjwwLomtvW7ViEQ
iROkzC3Dw7Mb//zm4JT2FcXesQlk26oMWD3gNBT5CXtTJApy6JEvNAzm4tw77GdhnqCioivYE4F0
fdob5yFAV0Y3MAyLIiiUi3PCEy/Dne4iOmTFLv+hnR9UH+PaWcX3nvqyIxElEKOjJehYv0Upbmv2
yR5aM0gSptJhZV82QZoDrvpe9Gl/X86VO6055mHN+I7YcX4jb29Y+fvlHB3Z9lrLz6N0N7clAsoL
5quPrZ3t30ADs70CZciZB4y8uN58Py288+xjIogIukc5CLpHJI8TIKVqltbgwGPyPIlDZ6akC1IM
WJYZo6gChnskgT3ojCAkJl5SDh67MYGULPYZKwZXRkvAnAK1j+GUtaZymgnALYQBdNYWgRtfhoq8
FsRxL+VoCsEMdtR+pMvUWUEPx8iCXnVkzuuDdUS9SfS5ysxb9wnT8B+sCHhZAU4Gn+h7YTvbRIUD
LJ2EFcp3FgVckBnhJKkIAi5VVl4MrVlxr/RbPCn8xaFClO0HhWw9jgrLtFrkZM2KbBYg3HjeUvXv
rkkmMatF2D9VudyOWlf9fWYiGCXPLSaAiP1Z353r6wKNymzpgZEIRWLFyJnHXq+TimPBEKhblTVP
QUsauI0Iy/tsaw8GUQhMEjdT6Vo0FcPYfghyQDGhd91m5Kl/bIOokkQNAm4UIGp0wRrY45h0b+t4
IehTtVMHiUKkRLdeGMA9bcpk/6QtNi8hLkIvPIzFOiVYBWihw9PxgPtZNgXOKgFQHWzrE67oa101
F7e+9NjL6s1UktMp4+Z2UrVfmqJC5CL3koLWiwTECXpPmwJxRSid447rSaIknO2hUpG+aJF6V9Va
oGCFRQfAeQYCt3+83whqnwM0oHA8GAV/oK0+MS8CRrzpIohiijJYXamFya8U5KoCSuEDBH0a76Ol
8KCTEKPfgGMizI8wSmKDQKDITRJ3oF5wdMwYdtmNAyG0V+Nl5a/VtIeq3wfnfXsfR6rH4VeTSqie
z4SaHPXim268WfAx6RQfz/miK8IYDyPiuM0S59VE/vkm0CgliR2V7KieFygPRNqXZbIL5UeelueL
BWpJkdBKzOfexhwSo3PBKI6H/m6gTo5JgMdr5a0VCxtKZ2RntwWgXZsOjTXkLQyoVgxPO42DmlMl
QZ2xp1ePw8XNeO7t5ZZEMZk9qLKVilC9L0pWuxDQj2jG7j5TIhnxEm4E/3wdqY+zamGqf6AfECbR
vS7plaWxgPyFT8FMZixGEsfxrFRPAQHpLQcQ+TMUyECfXUE5gOWmrH8IeEnJSCl/h/p+DZgeAQzo
m/M8g7dxWyuhZ4zeqciy4kkFI30Y6cWbEtXF7hQSuRCC5nu5lGgD4u9y0C76GGxDCOY7vCT5dw3r
zL0VNB//RNZaAGuKxNfXBnvwL8oF+8DH8GdaSRfCq4el0FDFpOVeno54cxHOuA3OcoQa8mDiuVEA
nWECkCtVy33M4kUfdnbCUEhiwXLPwjvYA4u8Qfz1lHifli1Z0oUnH2W1hjBZG1cBFR5GaC1kkuSB
zIBFJZWYxNTISWArO+EQ+7uP/Wc0yFGqlzfvQOtQXGx3eEFdzIQoN64JmrOj6pG2VZi+PTRHLKcd
CIOOvOLmOohy6pq2H7lip6VWnMPNkaekJLv8qKnQz0iRcIVpbFRnrN7dPO0XBqucjtH35HVhHR7L
LwdOhPdqLz8S+HU/sxIqGZNAT8VDrEWQyOuroFklwkqsNfIxvFTnYe1ztMJYLn5KAjcUjsgyAiU5
P8wHv8wH7YhaOrpaXj4/MYCzpQL2NKltnYxn/5yd3uUtxHlG9UO5K1NAjQzfx11Y3mnez0a9Bluh
QSttM0QYDLAx9TW1D6JXKhxijX14dsyBcRAcNOMLHjP86OTCBH8V+FIP1nWArLpOV0y/fOYeUV0v
hlF5GBFIGKe77/IXKHDq4zjoFlQHe5SJlXc9++KWHwNy8pDQJCa8wm6iLdzwtdrR8XuW9ER5DS86
/j2kDmk2AnXoxqlCIzMwb/fTyd9UIRo7HkYHFGMTYeRn9tZcWfFUmUf7K3Cq6sXN3C9qNn1dTPGw
Img2FDJARX3u5dZTPeZIlKaBewCIWuXxzHuR9M4E4NaH/zQaB5WwNOtDSM6878hqU30tJfQOqP9U
S5xWUDnr1YeJ7yIYCn9+qmSRoPQ4A6F9NgSNco/MOdkxeViRZRKZ7XeHPejtnqJwQ6pGN6o2C4h3
py3jeeVi6CZ1UIvcg9MMBMYojtAou+1eW5+rUKpX0MQ8oLKvgnig0zLHICMKeIHwZtNtByqFtSiz
G2DWKqstgkCfefE6EUJsRmTUJ2/TuLYi6Fxx37o9FyabIS4KD4BLny+J9JleIjwVUI9C+KtEmoQ4
xsOefj9nCCygfaUPRdVutBWQHUUlVtZRcidWvYClQc9bawE4ArFP9DGRMbOWiU4CTKNSbfO/7GOO
szlWsJg6z1rZCbaRkfgRtLdfbdekIsDtHJcAzm0N0NsErkL1g3o30soODk2oA490k3zaI3kJGpc7
VqR9eyfGz07BGuUHLdGmxoOq2jnbhDEsr+Yiwfbesn4kRBlhYsdpQp9hWieSGj/RjsGQHRe0OEYD
PJzsjyozz+2I/YGzMIgYqhLY2lOyNtgFoRPmFU5PanTkGCPLWVhD9NI5Rr6KnFF6mLTuVK6IJIgy
Oa3V11h7Pa8Tag/b4wygDImRRoRDSvG9Fg4PnyFRwxY0tOE9Q9iOMPl6pHvKyBuIuAt81nm1EEgE
NjoHUD3PPM0a19H4rngB0XvB7pn+vJ3T44qy0Nc2JCbdIMrwtwG59XgfPG1OMTV29zGe8AwkQStT
ThVK2PumFKLbLBGgauq/Hr5F+AokD4hYqHjWaRgpRp5bC+DM1gBhvvhhrcn3RVngwsZNq3zF/nF0
YWkdioUsSBUwSGK5enAhKRFCd84YguNhpwXLAnqRsz45JnSqW8PhfmkYJvg26dqjrjbGjQKTlaDU
bMvO0IvbKzE+wnoUXA0FIpCuxgWF0IltJw6HtVgZY0evQiae9GstwfsjoZEoKOQ7tJPYzngYtvZR
XhSnvXivbIXZEhTPJC3L7007txhA9RsZ1nFVLq5GRtGlyIRYKkXaQKaV1eQIafE0y6Jkse501rnC
RF+LyxzWFESWJVWSiXvequ0CT7w/VbJcZmOVj6GWXTWrZOYtmfd0J038TUVKBpFDJt+TZjRcNgx0
XuP49UtHOprfRZEkVTcG9Yhm4tCAcpfoDmXxYw1Za2Rv3si9rczOBOCW9wG4amYCnkYCEasm/tpR
IOPM1zlQhXW+zbcvHhT+XLmHAiLJynuRqhAkUOFSkXl20kFr21IMICgfeTSy67xHYhWXgSzfS8Q4
CSFGFlYObFUHibO0ezCQ3xIBUSH3KKKFVEzxpT/2apFpfQsgP12nVU5d2B5DclFUcbpQ4QOnFGBQ
9GQnzkzV64+5ClZxy7qN4brbZxX0hDaMRp90zTrvUVEvUq8Cg/XQqpfLJxRB8CddjaV3XJ8hUdYa
ygREFORoxoVrS1Za5L36Mo5bZkZMa3K5Dd4CrKdqvick/VqOraBWb3jfAHIbU0lzQi3vY5GgRb2C
onBCyIa8ou9KP79IeMtUMC8PdAZVL7ks0rsRNwwCopauJyQ/MwG4hbHfw0Maa88rA8/e4J9AWmGN
RsgptMDXXd0Q0KRGIbKYatjEkyoghlSznpIJBNWsUeXO7QDuj4X2SvX9JZsLJU3V9zkHT4XOy0lt
izvD2x78YG8/BEEZgvJR9m9BcQ6ZG6LgDHcL0HNF8lOsHnHF3JxPOE9NFZDvxZHoHvs5cFCOdJl7
ydcUIIXi5jBZjgT51Y7DtZnMxS20TAIpTdzD3s/r0dYMLfBf+LLQZ6KKGJS+N3EhCt+gNeFQLWJF
r/YDguFl8k2Qud8EQUYKZD56pzmhiUdJiJxAnCLI7SOvimLaaAqzBZEQB8Icqj62oqaun2X3MxCp
cBsMV2vLNt6YTl3sqU3kVvOAeFwjhO7/R/oOL57FOdiZrQG6FC3gSdP4d0X1FFn2UkTwxGya/Gf8
B6fv05a/DpIZ1LF4IZrhlFSAqqAtG3Ea2uKqWxQGrV4FZ27vuPfNfTsOiO1npWl9196eiV6MZPh9
OxlBxyHyvnjbMUaY2m/O2LPGXO/1OzHHIa83ZZ2W4xCXDmYxXTGkDM2w7GivnqssqbqQ1ad7e+GY
vrhrIoTUfVVNgKpv3WY3VJAK6wCLRVaOgk6FSWV++OyrlmY7U+rlqmVKlojABTrsioozghQBkdY7
kc5WRX+kq21KmlRqjsjZZQEcbiER22UlCMF8HUIV7kmgjM9SD8IexorCOVNdHkp8isCHrKzHz8q5
ZVqw69XnH01zpfNqxHe5K4KCRMlKTWiEQW6h79ShblmGQp5N6vMAENKltHE7EYDbiwEkanMC+zyK
4QwH/nSwSLTpA1vaeCxY4VenhRyHZYpQC9oBCaqNAa3o6XZs3YShrZIWjbNgrLtdIBERpmzXQf2+
2Bt0K16cU6tVxfobqJetg9BIVdkACkkvuRfNc4RnhkhLbgJfiPN0U9WZmpbZU2cidSoQeORQ9Cw7
M2sWY3FLSI5Ru0Mh/2I2gLJZDKimSdrSiD25g+oJxliz7EZQOCxpY4VYSp+Jo3hHCqjZbQTFh6Bm
EJU7D/1sj+0Inu1xesuBgKiBpI91TwluAVXyRJdbUkWP3h0L1OauLkFoi50GH023mPh+lvMkEckp
6LejvkhLYrGGOQIf+pi2sk2fwT23KpnZ71SymV4+l6aoFAvyfLZzMXkAbnkKAK3yebc9KlDxAc2a
7MdKiZwypNQvFoxdj6XIuFrYbedeuqS/NuxxoTmkRO3WdbOToI+WFwiIhehre96xrhyQBGHWqye1
sI4k9N93WO9BLrlj2wC2z90fgr+H4C7PJyATPKAeGUel92d7RIhQ2gPTwU+5N4O9hy2asTZ8r7C4
58jO2LPCIVdpzeF7Ws0aQbEYkGbJ73YrORnSnI1gE4ugZbJJwquqdHZkddFruScZB2sUucxLsUH7
hNywiBYCz4TlP7skOTUsz8qALUCBfQBVugExUx9zSJgYMRixKPLfZfZQOltuQUoZurXiWo1HH4PB
pi6qdVHk1oUkdsU2zNZW6ESAyGgqTHVB2jnJ6N7h83tGunabu6E1ULQARd6bhiBnAnB7AYAsyLKj
CnizR7kzZeWnIaGg7KtrfSd/tafDiviW7sVSy9PcKRGg3p4i5Nil3M1ENoNn4b5/w9xVjrOqjMPX
4wbPT2RhA7Yut0vOjJKlVLxJTkHa5XxlDoPyDRvcr4iyR9VByDBijNWMGmgtw0I6OSFQKlapynaG
YhSLyW0DbrU05svQj67okfeGSgPVQ06mzKjS9kDaVLwmQsecIwAKRI8T4Hq1GD95B1Zl/jcYPHNT
XgnwvMROsh0Zxh0603Kib1hW77V/BbVePDD7eXozx7MhKNqWvu+Hm8YHt+Z43ThwWXjkWTlPGuCz
RACSElaAdYYwY+WnGwFPOAbldLSHxBjjQBZ/74gXp4oZhaPsmwEmjBVY8wvo6stCcR8ze+xe126E
KCBY5bA/5QQ1UI+mbyua8DTZO/LVuGHiV/wYJB7+IsUZQpGuFf7wBrulbCUyMPpAE8Jv0K4s7oHQ
vJZzAAXcbLUgUyJbtFpylaFkO3H/ELdWKt5/Hj3wCtMOolsDNsXh8XBeCQ3vYOpf5SRDKLOdt0AK
hsyAZMXPH9fychtMn3WmmkbhY/K56m3KQNWM9TjvUbyHVulu9AC8xwlm6e0qks0dPzNYHN31ZXuJ
hN/op80E4KU1r/ikGebE8OXekZYYB4JE1F6vEVo4ZD4IiGMxDnTJWmkjDJk3KRlyqzxBmtamNsQ2
Kb1X12SqXtTPoqILjoHFLVB0hq8vgsvuywjLTrElRmu+I6jcSBbya/TjstKIEhb0AVXu6H65xziF
kN65ylt7eA4kg8oTDyoLXPHioukAoFLTKejvyiROBS5TC8Qr5Efx9NEbVzRgPFT9/BwOZawgQNaH
ygrSV36wQ8SLAzFicpRYEFtNnqR93PxGYIEEzXBttRSCh7PE4436NrtFqXBq27m2SFO//0bpcpXc
6rCfig8hhW+egyoJQRgzAAaCCJpIdTkOtzTIaprNsd/0F4kZv5zs7HgApNe4weY00CScACO43mIr
oQbsEYNY/I5tBS1Ekn3mPEs7/pFxTnbGG9zJq0duJWd+UQzB8h52ZNMDyeYiVF+51IQGAq+J2WEY
rjy5Z1gEYC6FE6Ac96RZAx3Vy9w7/z562V2fpxXT4aM8LLKmMW0tT2b1Vcf95pDHSpLnSCCTgCeZ
Sz0EYQ8JylhPCK29UOkk8XACox081OhDpLYY/oNKZg8HSX1LOiDbgOLniXJWyHUKKFuEu0kj3uP+
PpTJDhbI+hJWFwh1xjSJwcd4ODa65oa4krwbqCGrwpHEECHJ9LhdNEDmsOtjAtlW8jE6judlf0EH
EceywNU98LzGidi2g2wM+Q1SnZkA3KoOAL8BfRI3ZteRHyfvuCu7WCkxmZwyvznIVaD7IEjwehmC
WIVO/gt9phU66QmgHQ0yZZ17AEMK3YyUFFpk0ixHdmOciVtOapjIKPYAPbV4LPSceYOj07dK3RhV
esix8yS0BDbZy8sBIzrIOiEoEpCoVx+3FoRAqnZsstsg92ygUZBaXijyWxT7zqCKqbP7yUfmKXLo
J2+B84QwUFaVUy7jjRdBd/YDnXUh1GWmfBApQhetjPjnmmGSEzjkc0VLrn12Y9WmA2xYZdfCPDHx
hm4x+DgRbQXSyvS7EB92eEVk6lgm4W8y89RbSEhJa8yBq8TWTTcpyun9ApFIw4elv1NoT5I49f5W
TZvMFsBtD/7CqNYncRMl7t5ZHtFBIwxEN2guOjsE8RdWl1HIEwhc18wQF5WrEKC5ojBDOK4DxUwT
pZ8YuOJ0dHmL2GF5VjMCs8I5TXxX8DcnIR06dvM0fY4yYQPpEmBMvCTQRu6fMp8CbMy050Ha12W3
nq5JaginHmP8foVysSIjB1RJRS6JDrfb7siXFSJN/Qh7C2R1LxRBKCa0DALCBN8CH9IAYky8e+Wl
74cKL1FrJ6yQxeuth+fzfAHK9l8RQONYPF0DqOXklrXrRXCnYFVE/LmxQg2VLTZ/Jg8amoSRn9kE
hg6bIYTaOPsYfhZrEzXSacecaOZNhEDCUoGnjAa5pU2pashvqEl+1EBAUP8c0Uk7kblIPpPEU2Px
EnhYJgJwS+N/kcXHl77923rkwV9JA4CnjR0J2W7LgHCtCoYVV6Bj94Bsb9TEEY4KPPH8u1AwiHg6
uL1jrN/X43Wi8GziN4QEbMQ7sb9biZR4xh+duWDLar3RyLW+7SZSxNVohEAF/aBszsvSuqq4iYnM
lClw42ngBAfenWilAtiRk7xE6MQ2Z15XJL21EKBu4b/bfsaiCNCGdAUniKJlVFXEXSAp3LfkvHOY
7GIqkRsjQtVjENXLSdlIwWwqwBVQpWrZ0r2GvYWGmDki9uBjV+EwC0hZRKgbgLwSfS+UvKppj4T2
UIl8ldobKlnplDxbWItj9kv1M4rUSXsJuU22lyRxodJ9jIeLOyaq0MRJfQyxMnq+/zlZV4Gyss1K
HCkoCgIE1DjOZY3O1UQAbpnxOYvrT+NWJu3kM7kKtxBM1aggmWExEgU7OOrtwJPMpSCv7kKMQtRW
yq4SIFJhywovoZP2tcoXW6PWAu1Gc9JRTXR3BIUqWBRYo8jTmgwX9fsPhbOBQoq2OyswD0EF/aEa
Y8+VRCbccQn+nFA0mNiLQTO3xMaGAHtyYwTspGipHhZJU+JgmIeEVp8nPDAr0r51DLpR010pXpnl
0HOALQfaFFXajhXPRvDKYqNkJUndvRRefHEUblohsyDOASA0SuKevpwKSlj4HUBsEYahyFJpk9n/
kjwXnVFCDHlGqa+cZTlyDGB8+TA8vBv8Xhse5msHii4hyh/bmT8RfExAasR3URsG8Xx5EyNzIUXy
PnjMCE/Yfko+pli9RWoFFzM3ARFT8aek33yOs39n2gKwLqe2cYO71TzjjYfaSNPe/VDl0W54gw6X
zC6GmCnybitWfRnCWa4m2RH050S+3DIiYUAxg67UxYIwGmusy4/RNSNUk9dBq5yDrzNCoHzwPMOe
K8I4bujWhV06y2Ci+I1JXViiR7V5wP8NDrwRokaAyKE6ALEdkKBs/TR6T6l6dNC1QXaV6/0oQpoQ
Wkw3CB424gBQt69Jj/P5pol+V1pqTvQa0OqZkjUFmpScu1A3pyPN09se30DkZb6g7unF2amYDlty
6Lro6NUtXDxUlEEPwPqRg5sQbqX/XZauaWBZqaSRk3ESGHb/U6BOSb0nEWLpuiOw3WFwnsxSoOTB
W0aywOe6nNdjHxOS+JQEZJg/q6JG1KseO5VEz4sV3iNrIUYditkCuG0tACHBFo3vqAaYFMKgQbJe
UEUXwSCIu9P71tPKMgQz2gSQyjIo55U9OOg8smjDhuEZFHgl3wu3XY36rDyIgext0TeOdMhMU9zg
wFU2EETXfOh3vFgu2F7kJQR/LyfIea2Slc9GnAOxuvDBGWQIExFOFyGqAIaYqgLqxuAiknrOzHnA
rkRzf8b9LVEp4cwFL3PmIy4FgptTn1uGGHPRKRsacSJfx++1FWCRwx1hDZdUAdEloKpnJtcRUKw8
3V7smZGMJ5zaOdTWqYaNI230KLD2e+HBx7C6jyWacKGuLRJBHbZFg+WFvAEmUyxetPyicJCcbyeI
P0ifVn4GCGuCFiZMd3rvXvmcDV1hxU8fKMTmp0QJKZV4PtcAXzazAD0DdzmMjAmLQlipDoUcuIGk
/dJ4qtMZQuqned2HEF34vipDA18G7d8jqNrJ70OW8bWitRtofX0v0JVCKsNZblPawqwkZ3S/+nCS
DkGVwZWSnM35c6sgblTYtlq0ctKAsFmPQjxHry2ujyZqadeevfFmAw+LAoNESWu+5ofdlMz9eA9S
j7oIZGY6hR/16nMgCgw6UYwgTJu49EwtrR7ehMo5ashnmVrPCokmmpC0QbHqxgpCchxnJdyU8Kpa
D+PByMiyaB1m7z6mmpZHl04u2D0rlEZRJw8+phZt6gjMziqpa/fNsG1nOFXCynTZkhFkpkuPa6MW
mE7JjyKcdVCC7oN7NuZxHfh+KPrUzyiSeqEFuezymZAeAM4wBzg7JkC3yP9vGdre+v0BCtO2OUJr
NMgBBjpel7afTmdb0Y8VdNSMDrtX31pAUARnD6XFLIikWLqWavVvzHBcTDEfYbKaWceTbkLNHjye
AxZnY9qqQIHNuXxY52ZmOemLkMhJ64WGBUea4iZd74za16ghlJXGrWgqhefh6MHFxgp69e/T+lxS
UXD/On+u4TFApswdbS1UfdwKGhBNjDojrVMLhJybt2woubgJN9zNyIioWSfrk0qdG2cldPJ/rHtg
Ado3i7MkaQEpEAZCngaPBMWNYa8ER5L6o50UIUp9+5Yfr6TtocJIPnoarV+irUorV0SzatEJ1uLw
FEOBkoodGOYMwMszEShQyfxSxy8URaycSVfCPfCx8x6/KPEN5u9cDbYGtCK8izs0fYmnPMKx9aJ0
itDu5QKTuQ8GxIsxKdlwGguEn9YWGD5oD5WwS4XnBOXFOQoQe94I7sWgQvMh5O5SDXVH7zc5rcZ7
5KI4SPMhQ2bGAV1vygBjImkhYQvADlj62MLsBwsinVoTL5k4sZdqWLXx4hRhPVS/6UUIQcOrH90k
hhXCbo0rX1KPPSWc2Pk0cKtYuTIUHkShuGfue0lK4AW5Ed01kuhQmECSrYKEWHmRuGA845Nmc8Ft
T5SX6l6fd+wkvamFQBcWlJn3X8VidWXKAb9Mgj5Py/NhUl55dElVgFF4BRkRMOHRK0gUqdI3FZGd
tQ35JMYsDy/l3v4U9bXdEYaP9twE0uqa8A7s11lWr9b5+OvCHMX4BfKdFomJ1nmD1jNbTb9tgTu/
kmIVeLwifIwrSlWo9ryU6DtnMiZlRqqAkX4Edd5BPfCbSpToeJSqNoaWkt2gRE6fHWXS0H7MsuR3
IZ1xkIBNcYRTtlnLZXs4ZEJJPCIhGiZMo0TEla2OAo57pmpmFMjDKutuQl68H8BA+4KP0rbe3Hc2
4niQJozDNUyFC27OqF/4xE2WHcjv367ayH5LMKkSnvQzFSbGCXsgleLZiDO185sBoH12XovRIbOc
rSqxjNMBPi0D0aWF0wp3D7CbYAYQ/l4pinMPlPli4zoPZy3IEY3W7GIvO020Ux+5DHLoy49egSf8
wvCLZUro1vMDpOuIz5En2xMEKPS5tlONj0OxFxtbzi4eBUWzKw0vD5f2odMYZTztmaf4Bt1194Kx
b/sdTr3sFBY5sdsG0lpSOobXMUpcK4Q6yLI21jtA9s5HaA3T6kpF2QIm2vCYDI6mngH46DWuBka7
quQ2Df4KtXavSl0PxWFDiN8RFFTB4H1760N2VTsrJXJjxgR5pun5hYFTnl9I4A/6urAhtw8LLoKU
FKRhYGtiC/q+u4DtWvHQCm7Jotl9SerJj/S96D088IpYTngL3d+2sBVRMj+yIsL25ypmAnB7gr8F
bXLtwesBFIlRYb9DIBfBDZJf1FXF5hiWsCqTaH5xouqJtSY19oLONw/huBU0xxIk1hZNObBU9NqV
rFCuYlzL8AbzuUwtl+IwxSqdIBSIoiErJVI1MQsIHk2w+kbw4/3zjyb8YSOBIUsCJwGX1yjPFK6w
FADDlwiF6xDKDollWT+CNy2g/WunZAge2NdsSCqPkqLZsx7G9k4uRxraOIVuxAbpXYe9SuY25bmK
rLAL4Hi6pvhcQYNulQy1JK2o80jd+Nj69IEjI6hqevBRNyougcLHVG00TYpUcdKz/7DTCptm1sjS
Kh/DlbzMF0CTluYTZBPLE42yR/Y/pgNGwSFS+FIVpUJ+OdfA2MmvwiaF7pbekQHoOBOAW2PJeUd+
7g6ZhwJN1wDj9zN9eC7wG4xbrfZILKSDy5kpmMdcXuhRzhGHVTSrlUHkKjCAtc2V+MZDqd7v1zFs
xC0HdHpSIQMJlbzzdgCrLsVn5wUzGrMVSmK19ATLLY91BIfnhe47IzylKAwxxSUGR3ClmeFSWFwx
2qquUSo1QGRjy6DSjaDqGql21IDvoYJvRGok8tOuhRCsmFTvr9ZqouQMrZaBPbybHgNQTNQ1cdFn
FyZRoFSuPN+DsjCkVT6PGyrx7GhjW9GgHtQsVPBVAofQrsyiQRh2IcFLe9LSjDNAHr/6ZPOoWg12
RhdlerruvYM3smTdzwQtKfUgrFjN9DjdXAu8lV3RQG7ELITCzshnBbaPWL5M7SyHAEXhjiho3D1M
zroohHk9XCwzPC27DUG9E+Wg7Ku3qpYDP4egEB89LB1o0NJZ5CRJWwQR2Y4Y9MM6n3ffne4gg3Mn
QKDXRmozlDot2L3ch9gKM7ZtTGSJVMcDhedg+pJXjTpv+qoQOiJk7Gk/vGRJ3Fo2RFTk0l5PY/6W
J7QU+VEJZQwTXWb+a9dIf99veX+G5ZDHdq4XrZplvcsKOmEiSELBIRF54iNkDFRnMyBKKCQNW+Kj
Ak5RpRGu7TFuszWxLsrWHPGaewXYkifoG4VY9VJS1FAeQ2j3+cDHuJIExQRdfEy8xxCeBE7w0PwX
wf7bO+XesccRcpR48YNSY5A69uprTQmGDptDEcgs3nF+72LwRdIs1cSAW3t1FqDdi+DjgM5VAjBp
l80E4HaHfu3JMxF/pOLFsapBZt0x3Qgoy7K+ycVMdcyLXhzGWEFFSLXHXgRKUiTmQd/TIYgXy9P9
oa/NO8oeCMajIprHnqRbchGxaefsBdpqTX0tFgNC9dKxD4q0e9VOb4zD5GiZrSy2KeN1Apl61KR7
rMU9UmrGnz+XWqDhI2IlajS8sJh0KnKimxQ9g9QjTUTWMeJZbiXp0YkJkc6N6/pgnGfw1CNpnys8
v1rVwI1FlA7XvgbWOPpOmkdwFlpGVLqrp3y8SlArgakUl1T5MvNtoETjshQ1iBu/z/E4vZRuhTZH
gA/dA9V4S1BYdIoYJfWEZyKvGy5UKrIW2Ppkc0eDbxdAc/Uz0cu7D34jNIhb3GzIw4i5gICcbaXy
ngnALbZiz57WseKeceryg1WtuHUY4CKQ+4qrV8LQtvYfvionftpXboNUPHzIgj5uTIh7cmOOBwLd
D5nsoDjXVR8Qc2sIQLEyBWX2w40AaBXuPlbsosZuDwxaceRiEGmXHUzuw9cR1u8FPh045co/eJXA
tUTQk9Z5VEBMaJMXXRrzo9LZWvI0YKBp3qlZiTXSA/nPQDNQFtsApf4NF6G68lFRMrD2GURvI3WJ
WJvCQsAaz4iOZP/ytll6ZryZk9tuh+tdlY3RbLALr0O3ictggODwcDKQBw0gwnoI/B/H3GcrDNae
AMXPY0HrQFAbL850mZR7jafHNp4bpapBH6D4ES0R9p4oY8BBoOelQshWknreUQV0XWGE5SLCTfu2
rFh5bhjAWSUAKPaMnXm4LXO596lYxDIxOXnlnghVf0H442U3up9QgfA2ak1HQc6hcHFvv0HFd5CT
mPYCQRsGCbYjilql/FXWPJP/N2oBYOCsq/4KwmZXoJDF9qJDgkOEQd3iDrPnHmsBeStKQFWRfMvx
vsnQJFcZCFX0aofBRK7ifKhmmmBg4WDYqqFFK6AE2XNfyqXykRU7DIiihlvW3jdXYsYZWDNZ0RKI
BFWWxh5Es5KSPlnF2v7bTfURLLaYe1UrSpbxkYP0CtCTzaqu44Q7Jr39/vbz2N5sj2OLUFVEr/kt
VQ6b5gi4HeAKT7E0s1fCVeTKQE00UR+1KrnJfqb5EyjYEhGvrszokkx24SZ915lDoVJ0RIVMAQNJ
voJNEAWPB9T/uBA3QfImIXo7iXnMBOClr/9ZypFfothujdKfPI0NSJCMaoAAw9xO+62VOwXJpUHW
oDhq81SsIwx8KRWWlk+tR24yeitw8Agp4WQp6K8jUQATlOY9xDaUIE49S3UOUUHDoXQZlHSxOexN
P9Cdq5EwfR8rjlHLRnrLHLyg2xHka0AV9Vi7Id7bPvoVESUrGjjKJpD280JlbFrRhWpvSxzQfGWV
jGZWtnLaneYsQMQ4nCzVYHAP7G0uAf3v3QY8ROTAhT7bvWbAdNMNjpPAoHeWY0BpIryaWeCtf2/f
7zygE1gjKx/jlZ8x3tTPLTBNMvR7SwGwpAqoN7mdi0LYKgdI7bHJvAUhStxqye+hiW4JWBnQdQtf
fUwvqGSLgH8xUPiYcDwSSoCdFSZePc2+3P18iQDOcAgwS/TuQf/EKF5t3aVsOgapHXI7OvzFenV7
ibwAVTNRUN3oKCpqjAfHNPMOHNjstLwYLAzwelUzju8dY9vh5bdDeyR+LwdrtzgfUDhH1IhQRFJG
jGM2qId1vRGhtZT7mFtfNZRtFoWIrIRpSU51vSEdLwru+ciP4hZg2Rr2zyPTA2nW0X1GpcJWPY9q
FBIZGbBi0SW8tTd5N7R95eaj99oTie4Oo0DstmlyXm/0rypJbBVnh2ub0CvB8dGwZbjPHoqikacc
PLNqoh5VW8Y1YR3eJY/PomZOROFndMjZa1jPI/5S9PkXL4SITNCeChWCVSjaTABuYRtAd+1xKleI
oJ2rRoBUZ17xwiNntBmDk1euoqusX2l6sd3Kv6+1ZaIz0RcrzmO5j+lzuCKoq4qCa5lV9ZhgyL1s
B0gFtKvB7cPnBy+cagyWydntHKJRAijjEsF9FX3yeuuRgVmkAGS2lzNA5iHU96JrM1hQyvOs8iyO
2IuXKAmjKEHOeJkRYbeew3wIJiP2Sh+/oxHfrVIa+clr+DrovImh3vHOJM6sJYK++YsdBs7yJfWS
k0mAfF/Uo3jHDrzyHEnuvMoEdwoWWuurXwfkg0nvXEmSLD5mGf/2OES5rkPa7fgauOc8e2+ji8eR
VAZ8x9sAJ6qvmQDcQhQgiAIRChTh/ZPPtiImoYGbAWAgPPTVoK5eg/abfC8Y1f2PnM3vsfgkRgOC
WqXvzz8AVQ1V99uHAbXYWiiqTJ7Wz9TOfHcxZFRhql6+Rx4H5UJlyshRVIksPyfy78x96z0WEfJk
FR9CXQA3h52qsri2anuaapF/vnZ+I0EkeX7DvjJV1kCqrXnEtQVr4GZnaDjbEP6mbTasg1q6fwRU
4lI7NOBxu0DIPD0uykVppjBEWLSaYAN+kpAMpJmA01uyN/AxCD6mQJvWF+WWO6PliXjqNjiPQHl+
8yS/og/mdULW2DJ3zrjftHiYCcBLaxusrtueug7mukMjiYLHbVZo5s9T+yb9NOTakxf8SUEQ8t4X
ZV9qYVg5SObauEgDL0KM0SbgPYmy9PmGgdDGxh4X4MhyBiB6QM7sy1WjXj+0fjwTJYmWfQ1n9/17
HmBS+BDENIhB/ELVsiBH3WeQYktJfZMXLsi94G7Htvut7Q6+IE9wuXMJIxt/2xqnI9xZMFDlQ7SC
8OyTAT3ByFYLZwIxYSP0iGZoIC9FZiFMLarIOMhOGp3hzeTvuMuCPKSOIgChAKE9CmJ5ChK9A6TD
fLqa5oPbuvmZ3LMnEeLiCZhuWwx354tUQvhJIDMIGeGHVNMIyn5elTY8hIxiOZZoyt0DDysGcz2o
AZfRSAs/O/5dkQXUBhtTN9NtmAnAS98CAFK+LmQaotLW9QG42oMInuVqzN0Pwj4hepQrNG0iy2hw
SWF4YBPMsHJHPg+yWVr5ii95ZM5C6HMxgQgYUg4xPe1Eix/mvXIoPBivJawaVR1hh6IriGgJVCEP
g00xD1sZTohCl4p2JjRs60Wed0lU7S7ySaQhRJ5VCF2IQNscV/gQWgsYoEpctfug2oPpvIQkDQMY
uJQF3ts5LQfAioAvIcGrYtZSD13YHQMiVU3Kb4mvb4mShbVcnoIfIGOoWbijbkjn6QgJeDi3Hp6L
bhVp4VDKQC+eRMDyJec5Amdmu6BFoERpORMequZhtagf0B8BrRyjmpzvXX0vkqXsY06okpagTGcF
1W2Ewj9QogRBpgbtLeAk48rL0c5ODKiQUBkA2aGapQdvrv1Tzg7lJYaqklWc4kmxylk4BJly1gPn
QGMsC5JnCEJHZqXgjELqoVoyTpaIDAeaCLG4Ta+Ao+NjZjZlE+Rg4pRle3BhkRwklnjCRkgv+/6H
xi70mapHPhkIqJJwshNvvZL3m+zSN5QJJJMQ5hGEmtmUfhhKjypz4wjqc4iBbABde67607l2ontt
X7PKG6X0rC6JdgziuiZI71ihYGtEjd0oXgv4FfH5yf2pxa1MRHuisIzM+1tch8s+pg/LjnxM5ZNE
FRDj1mDffuhtgP7OD1pS4mM8i/sEDgvd+HFL0oosoNZErapzBblupepXT9z9TKD5bQyfMYnvzqef
KRQayd4prZGfvfp9fn+RNn3Sfdlrgc0E4JZlAIivZ1/n4WSa1bu4MlcFQVWZchtornu1apUJ6iM7
Ib86TpBpr65Vja9XirkPGoOo6J0z7WmpbIFCT9wJDQ5kR16pLRaJD71YB9Q7BP5jQuEnoDVYVAXk
lanwcnvEhj0PARYT6fF3dXClmpU/OCCw/kIMJG4pkRoFfw6QvjcA1ZezhZHSUOQhocWy9844QkLa
9qRR9mT7tTFrfZ7uFxSeksRRPeWx6t7RRvaiFdHzhronv92vOH2eHgu9v0ndMYrQmCUBrpQgxUQO
mrhFcU8P6wlCpW9Fq2JrxHtcM64CIL13e0RHboaiBeD5jvd7HZmCiwEh0ZSge5TmbdBFeRBbgZa1
ADp1shYpMt+IorIIZ4iZBvVcTTXA294ASJKzHJw8Do5tnu/Yj4VrIBe2NauryWYrcs+NqHHdij4s
XXOTIPWd30POZMRcFyTWq28VsiEnIQ0m5dAKNjhIKLwImp8QXvgAHRdaPLXUrNEa3FGGNc51gPck
HamyN2rdOK1I+l7vaE8VUCSklXglA9tUmXK1a6Fl02htMw9BLV6amRA9OWlFnEb5g8XkrVV4gube
SKu+gpMFkjcPaIs3ciDfyeLd6v5s+7nIg1uKFqh4TpS2FtQioGNxdS5dK4LAT6gg09CYtJ4iAuc3
mC/DIcYXPqal786+AaVfdNrtPwmjMlsgtR9Qoaf85MIGaW57mKz3qg8Kz2nzV9RFhRQ0WWejowTs
Uy3sYJvMYzkQ0OHAEyEcKDMBuNXx300hY4XR2AlSVg7t1cpGDAZZYsxmq/W+sCrm+so2CU/VJw9B
AL3izFtQkGtgDW8P2rKqeMh97JVUAesKb0MAkNgCe+WKU+pigCTsdeUBddYRnG2JBzJyEaQ/ndW/
th3gKDeHLCICQ8lLtMHiKKqZLNTWHTFKaVuIU42OPX56V41dBTaA42fjH5F524XaFqxWS6qCnDmu
Qcuery0kTEjnHHrv4yije1mhumg7h5IyJpTF+q0z+2FKPCt9jwgMYwC2bJhAQNuAsN1A1aK7zD54
tfZfCmhF1DLIaRfDQTxr4Ihb8kGDgZIE9TEjn8roIJOMhXvmBZpYoDYoWhHsb5CeMfTcD4F9qvhR
Ef94wqbcRz4mtxC8mm6eCcAt6wBEhDcKwliomsg5GlP9UqlU9RrlKG1QFSKD2fHlIWY47c2q00jU
8tJKj1k78nFGxQCDskKVZImmpA8BYYMTF/NifAtSfaLecGNK0/hw0kMDExEWtQ29fKUeedFDB1cB
/Tn08W0kZ2hQUCjtE7ckR0f8PGQ13toDVldb8UAyTwGgqMBGXReTM0E/Pc5mHVEeT+clguax0o1z
AFVhqBFSkQvmuADqdlmT/g2X4wahpC5h6QLO4Fael7d5S9yU0bJv/dSom7uidi75pSuXQTjrjdr7
yO7ZKIs3fxD6BgGPEIrr7XtwbMUpFO3iZ0bPmvvqTttJXdY3KxsqysWS0jWLINpeh4fkIaCXlHhq
gllocADaPmKPCf5cKB68/p3MIhRFnQdRjqxsgXOL/+eVAHDxELXLo/gFH2OEQ1lVZAV6nSvvUPlY
EJnp1aLok4UVLAqqMlHrw0TkVEbkg4ObVOIiQUo9py9KoCLgEyDsqHbotL0QByZ10DKvSpV7+GFe
KZEIxWAaYV3+veQEnVojET1KdKokMe0hUVLkETeoIChIpKmzkMxRoSKSsFJZD9b2kqcvqjVn5Eyd
tItTDf4WVbpYtJXafM1KYSY7YPedRGCb6AeYHyn1+82VZVA3LQIlcrxXbjKZyGJg0c9Uw4qMqsn7
m2g4euD39GcQ/Izk2wyWmBP1zHvebKXrFQpi6+qgnJR4apCEFQH3AkVA0ZaztMFR+1dej+VW5Vp/
HQ3B+ApNaLxIblO7J+K7bvFlc/dJBHT7IQCzXdIVFGHTC5pURDeWhSEQW2wBdkoqXjK9bRZ3txD6
sgnOrSiuYrdvt2frIk4z+An6SqDmSLe9WYWdgg2jYB4DUhKPGVSjtLMUqYtL/S5RDqyqPh9eV17L
yzBiU0ccxPqb3LEqiLQlKo7x7vQ5KP1A0HhHOOpWKaBi/3Upbkv5GAvARwJaqdCmaBLCPvZuws+f
l/vC1equefkeV4x5/cCCdCkCj/cI1Rq1cpLIV1X1QpKm2sd4OM+jityGf98r60K62Z0lPqms8X1Q
hicVX8TAXF8/9RO8ThgivinpQr7X5c+sZJ+p5o858rnpAZ6ZGBBPheNktSU9vPZe++kTVjbKUDXP
VBktEtd77dLikFk8t1UHrGJ5V1GMTKSB8OK7F1G/er1EUh1KYsMuAxi+u314y0NSgKAyH6r2IqES
voCCz3WX3cssCI4YOSKEdkPe29fn5GXYdh/rOgy9XSRw2Rm0292GRPHzwiBdGSx4Ar1QX2xCMcPP
4bab/qw8C+A7ufyYQCoSfDVSmr2dvAD3enhefM+9BGi8bXMANwkHXSK6kyBleHp8PPia1p1/QxK6
Sl86UuvMNXVxPZxQV5TkY4Qm1h+7qE4/IA0dAvkkjzRbUYwISPEgf3wf3O+Q4BTKoZMI6Lb3AJJk
PXSoKw0D8R/H/WqvGPpCwRoX0112T1TFTmlS+kqrly2LmpAFw4QWg6/AICL60Hl7GbSxy4y7F978
Ro0LFCxjqP0Z+g3MjmzvN9X/iiEpvBIl4eikUqymln2VSJ6kLShQnC6n6onLXB1i3wv0COebFe2V
F/NeoUZf6HmlGQ5kvKQKFL3Q9pSE32RY3fiMtGeFG5Dnnqge25bG8V7HWY0IJ3uQBUbmOcKJiK9+
BgMfo2Cd+7gYSo+R/AwwWDPFKjv28R3cr4lehOZG9Rx9XPTjxj/PRypSxeWuEfNMyEclPz4TgNsY
/9GriupFR0hHEReNRTdAVejivEASkvBAP5sE3Ivxd+m3gmRcUa917aASObi6ZtsOneCD0YAfmrb9
IQBS35Kn6XlohxwSRrK49HnaPXKlF5ZKC/s9RtYnJ8ov2d2+SYbuRXWp5CVIxC+Q2pECMV8TwkbG
JpQSyJAkUfQcLGl2MeUq9cqfZwmcra3UZuri7IKJOJOcdVlpQHqOYIa9gja1oqhOGpLCsUCkTusq
kroJpQpUgaCdMw8smyIQYyrtbUUjwEmpUlEhhGCQGfaUgjpK4kICUmfMZB/j0rLilbf4DhgloSmh
ch8ifr2TOJIFDjM3gYNbMB+lJSE/4yUqCAEpQO8w+xgXmWdnQaE9BUAPOaqzm9uuo1oHrLs3wgcj
IkN+bjOAZ4YARJpV0zlnj6tWtLTqAyAhKXZ5n+gVIhQo5hwJURotKfPoW55Ada4CfCDZib0KN+gX
UF94RNwuFMAF1AVTUh9xPCRgIg6MX1WPMj4I1MuxzKmTO3dlFHTShs9LXEXlgExmVJdJRyflSK0S
HDkKutoh/UvLtUAEUsXEvkJUiq4gD82p1jzqT4dKpln5192pLi4g46ryam0yzxK9PVlaNFi5nOKm
1RBHOj3sw3caXRB3vJ779imJDRLYGbaAHTklIoLRgy/A0gxO0/8u77wvbrYsfb7CIx8Es/cFFAP6
uyHNrs57wORDaWYiJH0eVjRh0cdApHUZI/OgUt1HJ0IUtUL91GpZcE4Yc4ssUwCXssAyTKrovpvK
CSP5mZDKVD4GQxiLVmv7SrMzsjWJgF4O8d+TDnzFzOW0BiSOkhyxrsn1Xf2KrAepAlcKTYaRO9S/
G64UrR8pD8JEf75mwC4F4gNtL3pyAw+c7K7fa9i9/9rcGKADyIOHCK2ZLhyyEQ6tWuGFX+GBfTBt
AARCGWYYB0JLB96SAOaJkOpccj8X3oENdLFwFrFDRpRIbHj6uZ2HAG8ygkFBomIzu2HzJawCRrTK
w7g9UuIdgC0SOuwIkiAl/Ewi6U9sh6AnW870sEkeuK/O8VmOXAj6EGlQ0Yu2R0CreJZ8W3/rrbue
nOhUfWAALNbk8lmw3bcpFjd9OHX01FGLVMrgc+zzr1krYK+M5mQgIKUqqoWSIKyO1k4rtzgNxo9k
vddM847YFolnm1aEZwJwq1OAet0KovoSGaPqwM+sd9vqjheB5xCYlj6kI5SqPojxrCc+eLn5cFot
ANKgMvTxc+HsQtGXg24jtPnmFRbyFdpAQxIwSq8pr0xJe8UTVO2RWQ+1lphH9sPQYy6XEaKITRjy
y7vuyCQtm7tBpj91g1L3Oou9bBwLnlcise/slI8gyCXxuhiiRBXB8aJwabT40Rs+N+urh7JI4BEp
5zo5lNUVY+R2jxS5I4eNdc0c7B5wvbCK2FcjNeAq13vmu8+rdWOp7yrhlYqWnp9r9tHW5RThoEFM
EGqGgOYU55+Tk+odQFQ8tWIzgch+EgOihevxQSEdh0yB8j62eQoLHCIeaNLdyjFNSRAxzmoRgzuj
a+7DhFcT0JAH49SJmAnAS2yBySnEviavydO74aBaqPpBsDWqARUPnOhlSwEl6hTWV8N75KUqlQL3
KPe2Q3RPDIJGlUomNurERYlG1Um2swoaiHEV9b5x5PKPzGFCamKdojmw4VVCMNEf1DzjPTLytcm1
BIKb+DQd0L6q5fUjiZNMjBSGwyAiJ0bXVfjWNKMdEyVGcBGq5Hy2R4FfdsMxGP4KsHZZsbvp7EZ1
rTvPbmc5sRTrchqOZNFMRft41sFzpb3z3iU43qOP6Ux0sAinE5MmcQ/L5EuE5Jt/qFuANUJAia2g
Nzr3w/z5QzKk+HBGBYU+aEn0qqUM4ULgS/a+gRMph0WTgAsCJQlN6Inv5ArOiZIXHBkwobDGZAJ8
eQABBZFZZ4JLTFxxYImkYePLAyjsS8EWQfa0JH4hhF0oWFkv2xTikkz/SPl6WKOqIYS8CBCwUO4x
CnJyQELy2g2sIYA0+FVVcdL2MBrwAopqYYOEvSBVsDwsLf7GbyTOgVGVYgh0roHnP7Q7pLVpXULU
6S+VejgHxEq/gZnsRBWwSJKsQkikDeQB3g4tAOKjPxXgmEUvCAgEWlaT6IdiCNyr1oIIDmQlyzYj
gB00wRWyaSCY8DMERr2YHCKndyWJ2OAGRZEa1VLwIniScBIiumM6qOauyTFwMuHtPgakHridi7Xz
6Ae8JlJei8pWQj09oA4+lCPPNTN6ohOWkg6zNS6tm6iKmPkkeCbCEjWztPsqlCR+HneLtOzAXgNm
JgC3EgVo3PWx/2d+nDpFbvNE/elQsYJgWo8vyLFvLBKTRYWccg6B1fJmvBdypqmwYBa0zBpbundE
CNkGanXHm0hD93ItqZL1AWtM6Ku1X3MDqLUlVwzjDpgNwQpiZipp63lN0CIKM9Rh0qpcePijAy2U
9PaxdteW0NZWijvPaT0zBFG5fqStkJtVtqhhnUKtXoWSapSg9+Pdygm05MahLQyLA4xIcHarqb3S
XciIQW+95XCamP0sJ+txEE90Ro4BHeQHsL1DlMRo7gzRNUjIFQlH8Xn2iqkUhXRwlKlu56MPLnp+
4XK7zZ18TM2uOUQkmDrbQ/UfUMbmS9u16Gcql44QxLYYcSzp0PPnVR2Z+NHqBtdMAG5l+Eeps+2k
Dhf1nzVNUMGbCJc3yGnzvygOomSYVqsCIoPYXrzQZfTgQZhCq5wrB4R2QSmikpYZaJIgaKiXvT+3
rBRWoSzlcGGoJLwC3al9QYCcFb3b+JwRFBdj18RTBViPWuUVbB2WxGBeI8HLsb/JnL7FuayW/WTG
wxGEn0yZ44q+btn37hi67Ih7wqmhD7wYDlWlQSe1SH6C9HxJfCEeATmj8Zi4vnPudlJMM6IWLeAz
GjS6PzFRTzK+jABtSFFM3ZTSuVTCExQgyGWXlSyt1JUqivG9poCG00lqSWk++LOJ2JDr+9juNXM2
MJLinaslJem57ZfYLpP6qJ+4Z5FFs1I4DCqCZ2TnRwRU5aSMNVX9/wDbO0Lgkf4A9Q/5sIS94yrd
9KKm2uvDWvo6mGCHA8reIotoCc1pZeOYlkd9g+7gW/XQ4AFW8/L6WmjNTnqZEY6xYh3zBvTDviwn
D4iPigCGplHxzhXPMq5FGpM+InBDIMHzeS21/IMVWVFxRqoebs1s6WWFjKowyg/EIwfjDlcFKsiV
S0E/yj1bOdtQf+iKwGklBlBdU4tkLkqXkNnDKmptl3ce49rXi3SLWKtaHoWd1zD6Gd7qcM9HIrSL
so/RNykzNwR+v8EjFebDHcbUasbjVMtWN3AIrQjinRVvhlW+gVgu2+0CyjVAbX/Unnf/XM4E4NaY
x3UlmYbNWbRMhy9V3KrXcdqhChzRvIMPGyhsueBee369rt5GZ3Tg+EfsWtJ6HpCTVetke0xdPqh6
d0pis9SMCNfpXvxrrmhTcuZe+CeQUp6LLHRqnZxgk45Vg0ysVxroscIrxXoygU4MjtJi8hfvn4TA
qSZTpxkEDJPEUYcDxZBY7wcX1b/vVGoW0QXfe6EGeUM9P4EIccOs5KqMfPkoWmUo+CYQ2gDbXy75
d3g1jDgscpFYtlEmWtivLMq01uunXghAuBX5XJjQZ4GhutjpvCpGWg0+SFKxA+NX/AyjM4UT6N6w
dDuzNcDzJAIqj7FnnxlJw1uPMKzwlAfDc+8VRfotjkcPJU+I7+nESQDwQfUYr6PqMQPUcxw7BLd6
N7j6fWjypEFkBajjRwMLPE+KBTgyVUpETDKKd8A+B8IQKTFLqmKjGoAFWLhX64GgKTp192JKc/Rh
MIrqPgBqOgME6D7xrIdHiBPVz8QQD4pbD7vwWyHDXSICRO5T1/cYUObqPzeOfsu76j5ExiJC4rso
XFMxtB2qYuQAV8ED2Em4keaHPPPeMzEUBgUCArEYGOyuWP7km4rPFK5jJE7G7I7ljcnwfp4B1ncp
F/weyKwyApV9jJevVKKFsOrVhN0gm3rZ2fkNAYZeXluHwUCijVaN2tBPI4SovycWK84DgC2ZyANx
VbHmI+UwvqYgn8uyohblBlBhuFu1O8htPcOd1fWIT/BIZsTVr0Jtuc+o+9KNRtcDJe821LUNULmX
g3VeVLcZ8qfak0RjWrCUmYxx5cQa8tJjJya7KG3cZy6gArkyFBnWscLAl2iZe3TjYchu4Ny8qnoQ
2SaRqlglsu+VfBzx8BhUaXqaZbbzZk3qMAjK4C5sT3pdyN470SW7C2rSe84enido5z0keNy/ckWe
9s7m9jOkJSEa9+OY4tXWRhoK1q0boc8tkS0vVz67j4mbSU60BvWqZ42CQX+jZ5p0NyTK9rRAPdKG
iL5ub9I/vKtbYt6HS0E+Jg5XnlCWmgnALTPaJ9VM9fjPK8ZiI1WDPAx2wTpUmL4cgUmmaZFnJSvb
ccz6PnkPVgLPUk8r89qkz1ntcoMHhZxdXLGNIM4+aqkXFaDAkaHcgeep/gHrmZA1xcGmcD0Jcka9
Vqk7vtGpuZUbHNafeZ/qhiYdIQjEyXGmfBUp2EhXl9aqthC1pt1q4fm/gfIhkGmYnQmj4qBdTHYt
r462xNR0xI21EFrbgcl9ApLSnmW1fgeiZcaoVg+E0B4SVuLc97YOrIOh6fdSIs3f1/UL8j5bf/di
OhPhE/T1yaKH71DWwOMP1/NBmQQGvBUmeCaqmE0+xkkBmYf3MokT1jUhqXEHP65Jsi6Deo+4igvS
SIAWOaNAH1Z0mE/LbcDiRkm1AYEJ0LKfmUOAL5M2AJQfW4hYrFJe0zLEY9AStb7A0z4qqyVYcCoe
YEoPdBcc/FnxDQqdKqoIpQRwBhSLiVoreMYbTWs9UpZaJ7ybCytUkctJtQBHV6tgYWBn0IYw4gWn
DSLyA10saFcVEDfL8IGVtA/CwBjJw1ZDZJHgSXbYjelyLXHJc22cWcw2hkpWllTos8JMsB40DRAD
gmeOgWpXvqqQ5HxUJD6UvPC6W9kmIYpcSE/dTYhqPV4ZygFMJ/EBpyFPkNN335GJ9eAT6IEhnP/o
Y/p7oWc6+xhqK7pbeeQ5iaDvR2QdNIbtnToXHgpn70qM4Z1Oq4CmpFaRRElWi0VHwHWQwU1RtHSa
MgsoV/En+T/S+mPlggJJElM7p2nIwSzXTABuIwKAlqmx2pl5zjZ7hU2rcqx7jZ49hoLsIBRjum8b
c27SOc0TvBV8ZjppCwR62NT8DFPlThVdcMwef3+CuVTf3INDB1ThrG8UuKIhFkv3XuFgMNmNUHWh
VB3PgQXk1FHdTppD0IlwG2vqjBwKDbJRNlh0eFUmLQ79STArkjAvGWe8vCTnD4NCG960XRS1MHT0
moVilmLiM44iQhjbekJsXX2NIfKdtk1MlpRNiEYHadDFZaADqWfsvhw+R4ZA0sS6h4Qh7gRokbDd
71WCYAK5WELXCcEjzg8uTqLCKCstZhnlkKLDCgVEH0Q+BLCyaxdEGWSqhhLDk5ctQk9VeIckNdFE
kTRK8otO2CZnlt69atgPA/yOlRyVEzToxjR/Qk8QuIEAwmwB3Ar4X9jOqgwy9ABj1rm1qyCDOq4E
EdQbY3IgrTZIX0ACUxanEfCZficKSLzeXo8SsbzLncoQ2remffpBD7O1PNxVuCRBsppbKDf7oFUg
gIlKgZaCMCjGlxB3dAs4lMR9PFHU6XDSHtFRnIQGRuNUdG3UazTuOyee8dxyCjo1dDuQVq2E7zxs
wFhIdvNsFprP9da2ss5Z707KmYRgeZwZGQypJlEmE7lVheP5GHPve+nJp+1tUgSEJX1OLzn0N7IY
hI0XVJ1BN2I+DDoSlgsDL6m/j5PxJBzFLICJoTIEO+FECISgZRsktBngGe86NeZW9dh1qDgc6niv
wxiHUSLpon6aRXgQ6KylrUT3avfa3SIT+DbMlNq4iYLrPGcAzysB6Dz2Ed7XojT2Zluv2LWSc1uC
KqAFTu+sDMjFuEsQcSH9EF12CtxuVW82E+90OoCCeLhBrfXqlCS0wstpO33V4E28ABHMkroY99dk
jBxWbneh6O1FNcf2/AbKOj6Y4UlMbvB92D8Mj8Ve7pgQBWGVTivCjih5qYXglInCRjz8lchNYLEE
UnLgqd+gzy3pPOyotMkQaxDRMR60qvgFaBCuzZYFcRiuaoXVLiXCSuOGIDMc++ohDhx+4uKSvApb
XtjS8YpbRylvVHUwnV9Lmxky31Pw6ae7L3QAoeddJZbqIQrldGKORH7GWQ4AIp0cXrTjPdsTv7LY
D6xjqw9mfAr/kDOaiF6YWQIkIEmlfgvi0sfZ2Vm1AJSQJmhQ88uadLUTJmpWZPCSRZcI1NEJxIo1
EPDI9azIMHzkZfFMNpSCD1H1uluAxRW+r/DvETlRAYhKVh/XD1H0ZbfhGlRbmR3tSymQxzjglcwp
mmSwipuHTalQcQAnhheLuggiIpFpW+mQJC7/bfWrn6klI1DI9Vha7+TfRxWWwvCQNUQhcgo9doFt
rT6jUvVycjRo50g7Ibwf0ZkzuuBQQR3Giz0F/+I8QSvEnii6tJDYP7SkYEWoMlEtDOVWFwfhkACm
1knRAkSYTOdtElGIDHLSDkpOCz+lUtfQFl5oARhV0pGXIWknOLcUA0mZYXiO42L2HsVGnOHgYooT
zOobETQAtneWfQxCQ8upacr8IJV/ny2AWw0BILUCKj+G2NMOXg8FbMSklkNlqagKOCCkYETBQ8fe
fYBoZmVdrXbjEisCbRulyQLnQifZ3Q7TvUhO3hWuT9hDhsozDb+iAF5wu/NNiNz13A9lJMAZEmHd
eajujA4XIU11x0wx0scw9Jih9P7zdFUT0kLiAdKIKMAz0oLiXPDQ1vgMwixWNUeELGnep+XxDd5e
zXw5sV4V2wPF+1i0H1IzIlRv7jFTzBgukzil1biCFrkUHLIg7JXe2zCdDgx+QNhMcSUFi2PwI+VR
K94QucqEYlmxsw9Z7fRCxTNRoCStA88IE8bMqJHGW5CB1PrUNquPWoJWf0Ths0h8HPpglPI4TCG5
pWsT5vIg2uZnCAWc4RZA7Pvn4TMRHPE+aOIk0zkUjehfVVeOAT6LLHW7pGUoqnpTP31ADMZ8gWH7
dldvfZRExT1sHs5qqzkI3cakAaTwxZDLEAVEn+CC3e7E0dY8XJRIRzxw19tpSuQjYx52KhVb15qe
KKwmZM41ulP1TdyrkcbaDAM2PEcZR0NAop112ekeYaG51eCBm2WPTHU7XzLPFzAF7DImRlgsz86g
gJc9ICkWZm0tiHXVzMwYsihXJESdrKhGUOo/o75pFpGu+rlXPADVO7e1OoCD8ue24rfvY2jDZsSu
VU7bIrX2eM4SUM6E/nqc2G6BiD3XiWhqa+G0e5F28aQCvv3Bv8DsqoM7oOEKzFAoHcjJwBTgvLIt
jdyrxY04+vcPbolR3uD7BHbz0e895dK50g4vZ2D5AtbmuHCDTxUnhuPWgFR/IDizDCpc0aFM4Nxv
lvPDpPOUrlqg1cFPyAuRMLMbDh/76Du1+jbrcy423MowYX4bYbY1Y+940HNboRyf5+I7Az0g2gfw
k8GWW1V7NNQ9tYltspqoebzS4GMf4znzzz6mutQbqEl6aL8RrC1Je9A/+MmFsVPDP/vXj7JV+NG6
fM/rzJSMtM0m8G4RhnyXOkvjaYZktgBeLm0ArYPLB94mnS1AVCiBxbL2SG9t2PMvnVp4dzNzFmnQ
U0cjTfns0bYWAj6lw0bR6GyLkWHQjqlWA4EJt0n6fUeFtp3QBbATvPAWcV2a4GS6Eyifg1Uyt76T
3+S9izrYxHZSOWlkUVNCxKeO8H8SUK0lAQU29lNJsClCa6ZSrFhjex+kNIjyfOaWQ/Ua5Gdf4Qju
aw/BQPFzvADtB32DgqhFhvKKhJcnwOF1wW0YbANwc8BPyBeRT0ktLxuj+Z4wdd/5jHWegIGf6bcM
YdMgsIuVPgaWexkDGBMnapOwmeMheTUJ4mOm0v6k9xNMr9au9tIc2ayZLYCXRfAH80SzW0aokQIs
l5qtaSytHszKlQt2d2blgFP/Kk9Gj2SBI7KBug1bBFcUzqeTAAWAWngJ4uhAVbcEeU0aKopwYedp
yCRDcS+6D/sxcY6TFjwFVo8VbHZivMsuA2duOlBYkCZF5b/8lDtLXJs7I9WxeA0p0CEiJ+hQOMbP
NuxZyH1z5CS3b5GApu0V93bpk8U8sWZjq1ombq7OnIdDq6o501Qc31HYaGK8wd00BLk9Lx9Vj5y0
w/IAXByhqUYh6N7G28IAgJtn6l+MkR63ao057P7T9oNXvYvwnvHnLn0M9uXIgDqDFzqGsEffodWt
rZTXo9uORxjk24PcUwnkdGZJj6APSHtr1XmQ8c7+7rjFQNwjfoY4wPkhACGQpEGuREyBMshmetqo
d04ZJ8LXlxRX46qWVpTrtB05vFbh1/O8X4HKIVOom9V646wHby59UA8XKtVK6aBrLvdqTauqLjct
AyUBgqA1TJqU6Tx5/z4E6uBJvCr5GS6OVa/n6jWiSuxAkACasNLmBTu65wRTNQdsOExppHnQdRA8
D7/JGeLrRKl/YcJUqSRRcA8Dk5Er3sM5Rxp01ffSCyym4DmodvyrJCWcBQQhq3YfQPTGyNheNYg4
Wp2Mg4R+CqHjFeUoruRW993l3CfdxUA2hXJgumrwKXFaZB30npyht+GgT14ZUS0mL07vo5dgRzkM
OMJQ4jx2xN2k1Wdlu0w2DqC6HjMBeNkkAnrWMyf8YW0PQRTazQdc9wonCtkPk42Y7s9GuFZWXMLu
rxxyjCFNs3pwiCdjUTkaKuM9ZPfKtseOf5VdWSNH2bJ4LybkZax2oH4S4OzRlkWjLSo0ARKP/ZrV
yKqlDI9lWyQgisNXy1Kv6zXBF+uroJ5bCi0IuNmOfGT+Pq7gGSYqWhKyAhYzTEqOvASLeT0KiXvd
szpCuX/t1Zll9E2SPxfkweNe+j5Aq7/3lBQsrQTiSBhEvD7abpO81VNATQUH9/KLPuHBz6x5DXHn
EzJpT9x1RFuf5N/rkvBGvQYecfcq+be9oIvsYyJKErn6A69CfO+EOjkNIIekEmj+lt8mPd+DuQ/n
wK/NrrjMGH3oix6kni2A2xDxaZ907VOnniB7kEQt9bZpiyCN+W+QbCAcqfr/PoL3BJZTGtJizomo
bFUdLKlhgqBNXt/ZeclLeeSMr2UYPVGq+rAnebhfHlNyybSrPnEb5gLSOl4JCLqVSozV10YhKORy
IAxGdief6J+3a+RdZRrOCswFeRBLlqSZuEQ10lO1FqijeT2PCZ98c34lQyys4JAjiJvprON5zfeh
gm2Z/bAjOguxaRI/PKp21iF4AoMtElAiMYKx96pcULXP1ae0+Qoe/u1L1rX/E8PgYS+d6aFrH6N9
RXgX641iNMw/UPuYOIjYkaDOaVFP1TM9N4QmnCl61YXGATwPOFafHzqRyAX9EpHcllPqic4XZWal
lOBoDQo6/ciMpqdaEBMBuI2GTKCrOu+BPSz02zZiHlEJC9KdzjzezZl5rkRjkoEOPaKo7gXyCjzr
rolsvOoqmuf7gf0NAIH4o958/HFbBUfOLsnNSt1eX0tENLPan6tX3l7e3akrogctWuuJOYyr0UgJ
6oNmhmulJX8HYUtuVMsi6Rv47mUfeqCuhrA6ZUUSJskSK0kCwnmAlKb1s6mCLDn5Q3DKNmzbpLa6
rCsK10Sg8GAX33/GQu27QmLOTCSUDaO+jj6TuBqW+fwDvV7BQNSuLd0unUPhhLw/V0pAadah/6p6
q8aqN8gPyUhD/1CcftcziFFR4PVAb9ELrDmFY/MLpB7ItN8BvYlkUfJ56sYieYu8UuSRVtIUQaxQ
LGFvxRj5mQjAbQYDKEc03jfeWe3orH1BitN117ahBRsjFk/uaSw6OpogQ2pesPV1R4xQCyP4IZp4
yuqxQFmJ7TEIeMGE2Cqqqj0RyFaklR6Rgzg4JKVJeJnT2iSE1xSbs2Xudd/aLi6rPqniRJbrLXIH
qbqHlSQgFXcq3qLoSExMXZfLPSIAFMiZ3S9qmuvngCJLlNTkCW8QNXVvkah6Ia1JZpnD3YGxqo+M
QJCXBHAkiYR5anMhoSOZIUnbIyoCE6tdyHDcMJGU5Cb+n4rpIGqADd67pIC4KUwW2g8WlSJdX0TQ
e9jfDxA8LyoAmoCV5z8iSluyxH/PfqZCKytKb1eBJkFPPSfdIVFyEHKGwqPVU7amo7pIugnqY1gy
24KfOb9VwDPmAaAJbzDEX/etGBpCbBN4Ft6Toxccte1Bu3LQuDLqHKgsystOvHlQ2TSDwqveqyof
kM+M3PbW1sBR7UzZtmgQhmSGEfLvqJkgf0HDYdUaY6VEGIfFnKgR0USZPHQVPBG0AZQoIFfT3Dbp
FZ0PjpnLWlhXlFR6YAi9jqcBQYuQNo1mj4Jo9dRG8szSthZOCrSthMhZz4xqoJ4t8v5e2mGPyQGj
ZJ40H+qgqGfK8489UYMhqv2NUByS6JXtFvq1btrmAAJRCBUW2cd0ClqRNg4JIbiSLgQ+eXhT2iNw
S9oa7Cdclezido0CjV1dEQg/Q0SPXFqmRlLDMEU5QkddVqfAtNiRkjhQAKsfpvcoDm2EVcLcCorN
roDuOPtfDfzCPDoTgJcL/E98zoNeV8/cg6MuVHNhKn7hLDjmnqqyClJzqny7GApk6E6T/D6U16o1
17UzXq+y2FYABadiYAxQBhFakkn9CFVSDGGtzSGEYQSY9i0H3ltU9crKMj87sDwvekLipSMibnfJ
6lTUJwbimOQpYhId6FC4tydMqDujild6cV7Y5/qAV0LXwwKtANc+naLY49QzpSeprYGE1IyG2LoG
QXTevQPHBbz04ek88RAjCDLO7aT46AabNoNWmEcgPaAgHhCTmFV70WdiOD+qkkpfGz3B3k4KzyKx
aJgilFWrTV0dt30ArWC5jnCaTWi5dpS69nEyZxZHUzwMfipi1AkyvSS+9DIRoDXgpGsATfwS4YhT
7eWKYhQLq/Gdd9HcmC2A254FFDz/Cs2pI/Cymy4wE4LjFfWbksD8ZKViYS+cPRCvFmXElSh6+Wuc
s1/dtbYggtJ/umubsvCIfQ985DJRf1oPy4Zt3x+DFcsKxak8gxmK3+knm0F6f933ESSkG++Khlh1
X0YRZ/+yEHqWCDznez9WhJESoYoZEnIeJbCRiSLB5E6megsV562Pg2uGm6PjLjq57ieeaqSM1gDg
O8VBTIQx6F1jsD0g1WRAb9o7iXF/XN+KQlfAd1h1i787jYgM3q+wJt3bF5rEC2eIh8+KuP/vknnG
Hf3ED+HheQ+Kp5u81tSXVOCxciDV94ZkAGVye34DgWc9A6AOLTKTVYG7fp1qLvLC6XFvuHAoQKHc
5W5ma54+Na2kOdvvUCSkPMLAYQ1h0CF3+sjH664492Mj46ko5eHE6+OjQIz8YnuHAmNlnKtZ9kfe
5zhCAEKEhbJ6KDH1JXWBsPKB3eTDbE3tpSobwCigFjDkePA9n53+X56JrNws1nClGpHta8c34qJi
6LOeeQmLIdR/9dGeXHGeKxg5Esv0EjRXnziRyeEmQaCkAtlh5SRhLS8m6SDPsUddJD9DyEnspRfq
fj7wdEboY5Uc7VXAXgRkLyU3UJLxxq0cRfg8qVcKWkrZbrkgLextg+SdExL38turGYaXs50hD4Ar
0UU4nEABnWIPCj7+m8pDmdn+Dq/vfgXqOGdKr0uAXPpMHpvtSe2uxOZCxdF7+yOWK1jWFc+u0EvC
oYp7oGY2DNSjEcoL82seiXNulAWeilzK9+rDZIQupKCeZR350X2ED8ASp7ZNyXVQUbHCRgQK8AjX
BqrhQI+S4IMqnzkJSWg0bckZdBOGzykLS+n7hYryXn6uxfbRQLipKDKr25JvgY8zrAj994RaE5Gq
BTBS7hlq2w/q/lNqFT5CZyrOEa/QGCtpKrw6cwgkTTI8X13vwCecICba/YcS0SlGMeNgfyDk8ptB
DhMBuMVlvw6IgF9SSC9bh1GCVrYHzXR2XtIW8OwYSMav9e7KXfssP+qFNAwiLS20XOpJMLQaGvhp
vt4hV7vltRypfCvBI1gxcZ0bBzHYyqBRvMo2Y4Ag7BEnvYtWiMe1uS2pchkK5VU9gYppMLP9vwyT
c6sIXqA1/Bm0D8+9SASCJqFv9lrlDh7W0r16BkjzEDy2qOJ24I/Q5yGgQ59+oghusykBZ+cT1Hu3
A+11p9vpo20Ap4pxac94e87uYf2Rptf7WAiTAcHydj32PzOvBwJJqjmeKRk0BjTZKEZCQEO0Su+7
aNIkM0+mDm0gja6oDfNeeE2IRMPJIu5VtHmij3GiCI4S4pWPiYmezDJlOoaCjxRCkyx8ZDV0Jeqt
qPKJM+MFODsEIAURMM85jkxZLhkvTzx7TIkRCsQRFFtAtW1gz3EjsirErD58ob7X9Z66M6serc/E
vXPmwGXRodyDCBVMhIw5GQFEWjWKd+TKSyuGhJowZ4OIE+nFJokd5NmFzOiVkQEeIvSCDZGTOtD1
OLqTjjS37sqY1ia5WxIpGcvwTEdJWhf+AdmU7N+3QhGTHciqPzqnlhJa8uth1gXF+d/Du9zpd6RL
IRh8JZQncE4IPIssQ5x3uXObpr3z27kX5c64844mlpRIvwoEoN+XmhdBaHS9qJxRa+skplFThCxe
m3tgjhyhesnHZKQx099uCZULvXN7XYFSrYc5MKqTMpICR87DUlGPAQ7pxd6en5gHGA2+nmf9f4YI
gCcqr+A0B3ila4utmPrsW+ZG1T+2/y6GozpywNsFkCE0/fljDhEPc29drtI0+w7/3TJZOdQu/Oq8
+tUDd9wd5j2nIHVvcZobI4S8jjzBv7HoTyJWQnZaaSDQ41mwPKzpvlMReUBicllWwrqCBtA6XkBR
G2siTFgnPSAjgsqoapGx4FBOXI3WQT21nLgiRXX9vB1RVY/V3zklNG0WAlJt+ZGieVOgSwJKprEN
tLDdqvp43iWZrPvKcVddWN8aulEvyR5jHW2ohOcXcPJTTameAPZh5XpVl7gvzIKP0SEVTXBYWGwg
hR4+YOljyM+AWPQ4WVY/U8hvB4KopMcyulc0tOxt9Y/FxIigzVDMxYQPEZJCmLK9lu2RuJ57lmLA
Z7oGiJDBwjHooaI+dwmUV04wgZsDARByNKsPFmK3yVXBLYwOb/oYUjF4gNsGU9AiEhMp2RBelJIW
re/OI8GoPPiojEQ3Us8U9jwqczlyen5y+XnnpKc8IhS4q3ZhnO4YUdvGKb7GaheH+lxnA51XJh1C
iJOQEXFsLj1K3tdG7PO3AKd4Z0ts3WuinjSIVnSrLCquFb3X6r0EE6x4IL6F0m8zpO6+pyZbAjpx
C6hYE9c60f2I1ITVMdNJE24fmaeN1xtWihzUhiGrITxVP73fM+RgGyQ799rkeUo/dCVTjufCDuhF
Aidrv6WClOX5INd3rfOxKOEWCo3mmlAt0phabhtEhirfmfdn+uSZANx6DEBWlvzIAIeib2xpJ5QL
TO0C+qD/GfeHe/bO6fn2Aiwi2SeqfnHomn6eo3iBiyqs4jqP4aNcVLaQvStvB+2MmxAMOWfqxmI4
dqP+Xgy5PCg0ksdFhZRwtdyuR2l0UwVWCtZYWJJj6B06jOG6zhVZ3xrtKTSggZCFNKHuo3W47JlS
QEPGS2Em/VrpAG3HwOP5sHK1VSWUCQ2K6xZlueklxiIoi5DVeBjajvR6ZU9ME+aiuANCAE2Hx5RE
JnQR42lxms7n1k5dYlAgCxsSjfMjtQLjvVLCKyFn4ntC/ZZdNkLxMdhJqlAXymMqsODMgtRuZBYN
SptO/CbcKnMqjRKbBiIJVMXIoTEgqljGFKLiKp08ALcfBihGaUFiNW4sP9mev0MrYmoldP/gKeCy
iI+qAUMLbKLnhXBRQYhVkhIw/aWb9kGFMXCQmKTgG9fdmH2QY5zcK0G1w2Sz1XroXGVuL/y6qjOs
0ABVsEmre/Ezb0HWo3Ad9UKj44lrkajmN0zFoxIpUtSGgIo08WGIe+09sXCVrR7s/WdmZdygI+nG
DQCexxN9dPg4syivCW0eIIYp1LDCAH1jdUAEIaNqNkSRqApiZseuvXejVpfr5L9v7+UGs6HB/sa6
CIh9Ocv6ApE8x5SKvLWPil1ByHvsAYWiRNPzLeYipvuYMreJp/DoYzwT9pmeEyS8SxNx8EsRNwPK
oqJGTSKqyBLfnGI0v+vQRH3Fjo8hCnJGOwvG1CrB8U375IzsvIYAS7lwXTWSgTEefGrnl4RXPDBZ
udWc1VyteHCL7WvW4z/py9avtZD4dS8G3GClXL1FEawgwhMkh/Vl9V1o1aMjNaiwDX8tQfhJvY4C
oQg0cTulGJIULgGAnlkF4tOQI6kCYjAJDeqDcmXl8pA8sEVSEFsRF02CY4SInyQZ3qgNTzC4eyUc
FNc8MwztCS+pEhyT8wFycvvphVNyhC44xOuL4ABTExkDcao9Ix+wKMkaFgG9yI6sVguMYlVOZ98d
Mp0eWTq9gq6RHE1vDUpySYW5QNcsXRBkbReTP0vQD5L38Z4JOyn2hgCdEtiC6wA8sGckj14PcPpo
yNS9YNzDUHLYXX9mRQssfrfU6amHNDti4yoAZjok3KnBR/uFMwF4WQAB+cDpwrW85FEZa/QCASem
9dkjQ38eT64yf39IMsC61Z6dO9PgMnTWtMHbpHVW2PIovcbtB1T7uJFvPkxEePwIJ7YjUg+ww+k+
uI19Qt+F/0DHAwZrRcW+syrRBQ6C2CqJwTao2cRd+ooWV7jERRVw5JytGl1PJBbgPqhFiDQBFzQw
5i1Id510tOftti+n284UQcwVP4anxNSlkk0U1W5y3loASqp1mV1G2z1R1hKBblg5JBASu05579R+
H6gMRjbKciuHNjmi6iGKZLZKWvaZl+jceFFBF18fOSKKafruZzqKemgf0eZB22ipnoMVyb+psBWt
+HHxUCl3MrmTtjN950Vi4IZEl0RTAKkNYaHwclGSnS2AWx30o6oVTwFFMY4aRlBnBjOzZam+KldH
N50GSou/NZFcJZpS99Lrq8tzxqbT6jGwBBUtH9ZweUhub9AIvsPzDysnk7IgDvbhaR5GTBVIPgv9
me2sBmEPmi92SjBQYBZVsSh7mj8PB0voWHb9rN0SImNe9Cxlv8wFeo5nTfbWWWkwzJGgJFfzAp8K
3YZWwuVZGIucF+0jLaltg70RPISd++DWy++qdvGKM4cMXdQ+xgfOgAVnNm+8nJadTa/RqO09mLlJ
000YUID5KR8zGqkOjKjlRcdmVUyjvUg+lbAdKUyTAFb5wqKcc8mPGwMVzPOTAzyzGQCn9ZkbvNDb
Sg9D5BlbKw9sJW8Lai3Uyna53qheqiI3KEWGxFXQkFTbW3b9fb63oyQkOmFPuYCcsVf9eDXA50Xy
oOAJir3hOqvIcDIGL7SXMfM4iY3C4TGfuZuNWQQhNNNePe1BsjNSZMtHdMBHzz38wi/FYIbBfUyr
o9hLNE7AbKhRELc4RIdwyz33zr0K7DZgmxyfC/mtUMA6vVsjoXnPlT2q4L+HdlnnP0hDe7HM1avU
1ydRWUdv4jcoUkb1x7ZWmhFOJv/h4UKIn8ntuhv5mVR0mBBDYehjqirJB8mScnEgzv94PXCcNn1w
fq2AM5MDVv/MjoEPQc2Nj5ZC6LrLRuG+DipAzXJ9NOUydKBx3Q+pYH1xh84TWOoF77VzsON7sVqa
uo9xTwauBgqInu4rbw0EjMAHWQ1L9lafNDpRDzvlA5Qg79MXjfQR5OqaqiWCYC+LQq3QC8noMS87
Da/CDjLN1fnhHjmKiiegGQ0OlT5ofX+deuOCsMR8Dzc765medoPHkQieMEqU3HcxL0328jsfYffD
71mLzHpcVadErvQxPuQo4DPReAXW0y7DPSiZ4ib33ySj6b5rHeR6/qJ8VzUxz1tCYwUus5RyINKf
BwZPGz8mry+mM30WbbUk0x2KQfeboiIzAXjJewCagWo1o8M2xgu+PVP0QBLBE7XSm4qcA6AAaVKZ
VSrU7W+LYGCBqMVDS6KGx62TE5XsYbqBUEWucjA/QGOJHoinjisVO4+Ut8q6KDOCgYBE9+Nd6fQs
fq2PwQ0btHy8+gNEgx1EF5uh+jw81XkSeqWRN8s1cXKBj3l33wOVq9IPg1oYwwVLt5pZzSBkUrHv
meYNhKb9eN55Ls9HqFb/Pant4hUogKEyWwo7W0/aB+0ehO8E3d8Cno5Koa354h6EvLzUaVBugEIR
0F1XQsHXFd/TnM73BDIAda4tKRRnH3KGPFGfd2IqBeMhLCj8Pof1ZAQ0yUa9sPguulKfo+BDaEV+
J0OJPoavS/J373M47ZrDs7SAEGSXgJvzmrzM7LyGACu+XYtTpCoe0iFKH8N45KDdwvCV8/6/qlLt
7T9jWJmPJ/L9RH6uxLmWCGW8Gh9GgV6M7i0lUqpXEF5uZ1CcYD5AWYg5wwbGwkWBdYzhQbcsLhN7
7D6AtEWyh7Y8HAPGcowLwsTgGH0tVxoBSj0kP30QiqfQmRXOj4xQab0yRnfXVHNbh+SkVRwf3/91
raWaPTItBg4ARBFYr5+fhSFDT/JGeSht51zISldsCUi7Iy6z5VYEPBP/UE0w8A+wgj2ifc7M6xGn
4hNd6f+/vbeN1TW9zoPW9e59PuZ4PP6InTQJiRyXACJtItEUBTcotElFUaoGiUoIJBBSJNRIVYUK
Qnz8qCIVCKgFxJ+CRIlQEZRWVeUfgeaDYNeNEzeoaWyMHShOzcRxbA/jmTNnzpyzz97P4sd+n+de
17XW/bzbkWiO96wVtZnMnLP3+z4f617rWte6rjQ6uf4cS2DiT57F4ifCzCpR/80rIfmQVP4HTJhk
h0zJIdWYRQm5mHxy5yKbthWK4rEce5HSuSh3TsyG+CmNUup5oxGNADz3FUAenAmCA7F9hP5H8NEG
6XCxM8GPjChf1p1z7agwJbVxtQ7p+n0GdG6HSKyrB5KFYIcr7VTpCYui6/IEGZdSIHG1y4XUU6ut
DvQimBu5ENSqJg+V+Em4jrA9ozCXKxvucZK1tZIQViyWBrnYde2oUGoMY5CozgdkXYjtiXMQk388
a2FEgLAXbbqZ4YH7MN/5x45MMqgQ8qQtUa7/i7VyMqCptmr0dwZ1uJSs4/mxA1KjRMbidct/brtu
E4SlLMs98G2MTZEgcDRtRWRTT9HlV7+McC2WRaSpPeUDOmSdEbl4PVWcKnF9nFEi6NgLjI2WZkSu
4H98/1ZkAYWhWDEa8OEtwVPQwtpszSvRZCsNTI+bDxi7ApQLmgT4PAfK6ZJbURp78NY2IdIFJ6ho
BAIU7Hov6XDXL/wBBUkpb9JuL6MKwyRUoOhsIwEO3ImYaBqRRGollwuG/CoStB7aSuBi3QRQ1+s+
ydLGAjUWYbqq03FLjod7srEeVnzceXWOYF1COUosNUmEbynMzeDsgKf9Jm9MhOk+RJqFPOLDdcHs
dkxmscioktGzblbuV5Rw7QqjLmyRK/wN13EHitGbPNNw8HtUkDxROMgRZmxxjTB/hnFwIDgeelak
C1AvdlTlpncgfogyzzhp52+79Rg7N4mTFlCMXB7BQBtKsTBCNVkkEl+6H4jy34UCoBY2JD2d9fWj
dwodxFT0odDe5ReNMlvB01ERMNm5JuQtGkpBx2uheYELwdhvHwfglukAOEHU1N2nCjHCXqfqegzA
eeqjbeQo5y6rLR5OrxWOFae69e+QPo8jdbOQyrVORSwsBEj3popo0tRx95Zni1p8bPrusCSGkoiO
W4eLbf+fSXurSdEeCzwIDkU/gSL55ANwFa6xMMJZD+6FERpnvQKIBgGkl6GOtzAMcknKEW6EG42U
oOpC4bpFOMSt3t2HQKkZwvbdkZJFQZz1TcDsPaofSA+kUQ+Qcxy7sU1xKAKAzMDXcY/mZpRblXQ0
YvJQxfuFuJ8+yzYpz+xcG8velWrXTOMD55Fh/L4u7yQit8ZjjuEDe9u5F9tsiyrLxgqKbtkfQ79V
ZDfpuCbpitAYD2n7xashXdA0cIL5d9iaGM+YW0AuC38CzMZT8Tb6DTYcugD4HT7+N0OZG9BiN+tO
EMnFqxmaDH98kmgQbExZzc/3gYrJzHA6D48PPyQZ2aSwUUzWfIZgUgLyuKkjL7fLCwT6FuFzZt2f
kDQQkhC7x3kh+lYVZmaZYqlKaOXB4U5Sp2rlW2N+uq63eqfzjNHdBYLl+2eif2/iCrkl9pTjkEY2
NKctlDDJyyDMwql4Cwk2XcMkysQjiDza0kO1FqVJPAuxsvZNcAZ8ndX6RRWHitfMba4lUQkPw/PA
iOb4pICkmQMB/YiotAdLYM0x+UN7sN6N9yqZR20FZFzf1Qvi6VCDFrh0xRbJMyNfpm55opMwzXfb
NfAix1hCBK7v8aFoRrgBYZdzfp9U8MdU6TXlgdlz1GuAz+8AQOZ4VYHAhBVkiVD95yhw73numWBX
HQnswN56kG4vODBtJsZHUFKPsZWhzx/WNLsOh8s6UyOr0eq7IduMuLZi8f+WTha07OtbMUDaBWCp
ZviwUKWdaOEmbOZF8duSiE1tw2quGwPjQpQCJR7gzHIMk/u+zfAEIYEV4xjw7GAgDFK/RNX36wPT
uW0xvWeqTgmCu6PbJXWV4YYgHn6onlKyDuLqcrt9njkDxRYJoR3IJD5owZza+yg1XVff49nAbvIf
12x8NhWRcnH8jHJOca2SngtgZOJoehQewVmO8VmBP9ukoOkA0jhrQxkcaQSCuDYc0ATfG4ls4yMe
QSLwfVCg//p5acPBdc6lBA5k9EjNlyjfxhwT7MiFU0Ojw0YAns8BwPaKwTO8vSU0ZLnXau4ozRa4
UZH31OmFr7eUvcwqiMYUtUpvrnJWL3EiaYdOJfCeIaeKdqbDPKwmZI0unTs5zNTU/PrFKRG62gA8
V0oko+zc7UI7Gb1mCCjNRHUcY8aHyp8hpbDsujDkiTH3GZA1NEJ6wN35NVSJoh9D4mPwBgl3QdS1
QrwWIiICLnw2EiL5OYBpq2EzgTYwRCxF9euh2zK2M4KrPA+2kU4wZMFEVbJafbSC25hW1zAKEyB9
3tJ0KxpYSe1VjwVcEMtwoMszyN4KeZtkpkaaK0iRfpYGATP73FBU6agBYWCT7imQEJRozDWsMTwX
vGbmC6N1SPjM8Z4BhaaEzTe5JrCxU47hlePqrW8E4HlFAKoZp7NdKUK37KefjWAza1kZripAp6+n
DyKcWdqL97g/i9pZLDPmBmM2EV7L+j8JIJjZ5PAiAkyhQZCEkY7/A5jaDbgVJb5Zlgs18Zw3sT5N
ynP8E6lDWkTvPdzMGb/QSxW8Sqd4R0Y6+IvXyBKz+ej5qn4y5mUuQZ2ulmtW7ii6nSB3VgZqMjIx
1Hr85XVIhW+AlDHEhdxdCoys8DgtJufVMnfZNmya6zuzlJa+MfEjdukJp5YOEyVGmBqN5OmBQrUL
mJXK+ef5YPRHJMDNKM9AOFKlp454YrFM+MlBKyUUWNaWyAsCA73zUAxQFkO8D3wdywN+uvJn7KqK
/AyzzpLfOgTgFtoB3+SRPKEpbxMvdpvA/sW/8T1Wq084Ae67PaS+pF4chmKTI/O5eXUcVyPTdw9d
Cm64CAtKQLs5UF66QuAjFHGVl3rMJlLaFLfb6UCaH2SikV4oCqrR0jzxragUhtWsFqjS1cN2np/Z
vwvMctp6mMHe22kOIr15IU3IAlDh+h1kKlycXy7w6cnHwOuSkZw7J3LBVkH9LmCBqmWhWOwlKH+P
qDbLL77zvVaSq53OQ7uXyefPnsrWwne/wExE2YMMsAfBs8nuU/E9BMvCBI2BzCmmcA2jYpoPbryo
L5vPcUPCDcdCcSnRzR4BPM8jAFTti7ESl8wg984j2nhCXldjyBVTCNnsMFjtrskec/i7hPdA0FzV
zmZwfqd1iu1nfEG9/vslm30Fi0UBDTMpfSq06oLMoWMSJjWhyB1p7gcQJK3s6PkBtCc4Wv3ZObnM
CthbrzGzsPegTNWQj/bHk7/jOc+ma7BTxFQmPV6IyNCdmF5k+W5ieY0AvVsgEKb3effQK4iCUd/B
izcF13Nv/RXZyXByyIQL65sMMzJ6N8kx/DnBpEkZZ5yUx47+FBXzfitwJw6W0+9UP1Y3OnJVbhs2
9SaJzBtHhfJaSlKowBiyBJ8XmjRGxbwAu40jgFtVAFyzhRcRhcktVZrZbmzQyHLF+GfPCn9e2HBE
edNoAc87qeEA35FxJUZyeHFOrTJdP8hRDgtZJWNvn9ULPbdq9XEyfSdiHnYwS1jtE04XzsP6zcrd
qBXo8jZC+Kl6+FuF3rpsFYgyYpqL6goTkkwyif+YsN6T5/0UUbaKhxx96yMKoXNzOlDj0xs3BCIc
uhY08CiOKEVE5ANUpEfxx4i20Wa7M2z1e4/XkdbfJpspmcYNZsSH6kffPZ33QrgI26Ec5+le/V5I
vjBjD3ovr6WdOPAhfy5qhqTGA8g2yq4luxTvBZoI0aYYOcbzjMiLd2RWrjg/j7zR4sUQp3B/jETF
yoozfZZ8BoymDoQi5rbCiwazC4DnEQPYhYJQdGd806NvtKU1vvqYcYH0CvnhFZ4mcZxitU41qg8Y
AjRqNCckRO03IHvMcfZnlEhDhSOrWDU5cuKehdSk8/UpOuTU2fscPYhEsoGgFxX+2kUJ6SoRuWRV
UGmESazVnfapTaSg955JD1LLXo4UuL3BzoB+KybAKZxX/Ws2CuIBJZ24y95/XHujgjdxHNZ/N9FK
Dvcpz5mPP/dwsJWgyqY/Jh3srJBTJ7AAYgcGW1wBi4WFue9MqnyOPqAq2/0o2ax8pOzgud63U9sH
jJjN4PojsRX8zBLZdLMADiTn4yB4o0eoN9ZkY8rD9ZVjMuUY/uwukr182CqRVKuSiHLsSSLbstC1
mI1bSIZrUyRdiAKY/TJuR9wqDoDvrL6NdSqjFx3Ic3WYk0hM8OwIcpW+aoptD6xXNrUm5B53HldU
e/WxwqeXR4RhqpUnOaSj0haCMAZtrelgTiD0SB4au7MsYoLwojBs7EU1DUKwNVGqVGeE8VRgCLJD
5KGYgZj0Rq2A6++0lHUMCSg5K50xpDmEiJRpju2aaZEB2qRSrkJla6y4y1ocueeRi7uXvudEMh2/
LLwaHidLYTx+CNbD48vRvok7czXMSrcqr2D/+F44o0cbc3wHd47vH2f/QF4FN8YDZQqqb8YEPBe8
JV7zrJUZZXYtsOMx7I6BGmFAmOCJCqkJIZKuobwv2+EckIfBm1hEWtz5VY/6G9AOA+XuvyJOUX4A
dF/A7oW05hBGDBvnxg1wWZhAKsS3n7bjMrh99k04zS1LeYvQz/b7kcd1N7N47QLgd2wEgIndqjYI
VZUbjybXhMGV4oAQubJVMx3gxF5xCfWFXW46jqKMJSl20mE6YPRiJrvDOaiTiwW9b9SdESajPquo
CXEfGDs3kQ1vSKZZbqLX+oDjUJvNWuWaUaLx/Hk2O1ExGbGE4LBXAeJ3ijPqo7iLS0JM6m38jfj7
wJJ7JaLng3SOKqea0pmbSFFn2VojZNulbkTaHKHyNN5L1P4AdA89MsI9yQU7aUdY3RFGXQsXGNlr
V0CrYPdjITEOc59sOUTYfKsaUp6JD8ogN4oWAbLRFQr2HDCTSbbg2hPlpZG4DC7XYPNJ8SrHZEEi
5RNBZ3+0/OPpBM7NmOc/IM/ohiQWGwA+NW1K+75j+9qXabV521wAb2UBwHfUWds/defxkHBCCWhX
tlLbUPydW5IJ+iDVrGhjl8Yv26sU1AWDQMv24FOHhQR4u6n8jaff784rTm47hKfcgySbYRCYHjv2
7DqIHXguiZC702oQqLuN16mcQpQCbu5C1JpsASbqhPv1OmTo8DAr8lyfsYKjIYVYWNgiS+r048H3
rtzk2CmIgXrMEIsPFlIqDiIfyRmxaCrY9HxZPKEevha4gFgNgwufCRBO61u6FunMXTip3pDWdqUQ
DZr/LAo01n6v/9/CZkpgbY1ypjazn6M1RJ8WP6nrhjGU7+JkGE14ZEXZTm68IGyg+ECP4pQIYj2c
kMIa0aSiDTbhJM38UyygMZME7TmHO/l+ePY56ALgOR0DVK2oJMTkFBfVn+ThY9gJCYWEAMeuFe/a
Pak8sbPFbV5d45dcmdgbvFi1cdtogueaSOtQ0S7Y69ePEpTzLNsHjyHCtSrLy7ptKNTL6vw3+w8o
CD04iVo4y/sWUr+0J13cZAR5XZfZ+dSuNnjA0wog+an7GBcklsmarMFzSN/hCshuvRXQaVW/qq4C
c04CpFt8TT9RaahWQxS7icgBYx46fnOCLpLqq6Ijoi+QRgTVKIIonV7acxf1vI25NxeLQ/EyIjVe
XiH3JRVDdY6xwtiMVSFjXuHxgvPqq6AiHmHQmCcnQlelwZXXDwbcCrlyTyZbGyEbXHxtz8kkB2f6
kaI0UfskD/50tJjlGG5fv3x+675RCQN6bfoR4HKEWXckz7lFsxu3rBjtdLw5CotSh+i6S/KpiGhC
vY4e7NmQFmVFbOpnjjA73ir9Qfxzq+1zyWyn7AI9YQ6k9V/ILeuakx+h3Nid7Oq7LE7rbJ6RwmB7
a9vJ61abOaUVwopdryt/GCRG90z8hFtCRlQDLaoCDojWhC+yWDp6MXW3T+5p+tyjYIeXEtjuQ1lV
qaTHbZthZDQZ65CQDKZripsjXrCYreBYproi3NodLQ951iC68DC7JoxZZPxHjwSrvXB2ilXKMeF6
Xv9MbM8GESyRG4wE96/XySLxcyXURltGL2R2fY502cQ1Ugs26fnJi4SEGJ2QhSip7mG85aZkT/Hr
gCWzL7/B54MCKJ4Ft1YkgldaC8Rxeyf81qEAt4wEuLPzWU2w5dSIc/VoCRoJdSg95GUziGxqQwOw
SIU/0YEfPT+GcUxVyJSe2bCoApY4UWAt+sqRK82bZbSi88KoV58+GfElwjcj6TvwuYusBJg8UhUK
VrtSKvT9RGItrtPWPEDgUklsEXGQVM1cg2D+A8aYENjjkMSj/vLxs9GqmnGnlepg8lHAHGml7IrM
6fDR7cLpKCgOSN+RSJ5vh1bTNIQrhVhm4ma21fVYSeRrlcxJ1TP/VZz8pU4oWfxLCGqfbnlkU96S
aGKz09ymkUpUwJzdh4oHgdkSaj2J4PFGIQgVoIvsgpgLRiefIidio16nSF50JVmbEqmNHDgJo6pM
CdLIqZUAv07GAJVxS04MToWAl9Krs+0CWNzvthJuLSFaYJ4UPR8sCqWi/LmqzTXGBl5BmNV8MTzk
nr6XZ+ie6Oygut6Kv+dqRTpNoV4Wd+lmhuprHIZInWVifHpStZm2FKAM4/tL7KQ1rHaqA3t3p0EN
dUQKFvgEStcRTnVwZFzcpn+ey1r+nOm4ViU9P+EGV97DcYpt16Dw7siERtlm8PpnO31cz+98dTYR
VB4QHnKIjDWn7yKN0VGLTKaq99/d9qfrlROmFWI+MN7br81uveDXjT+DetFommmMeURxuoACagf/
FG1iPDXjILKKjkW4wEfgdaG4xz6VjPZT/C33W6cDcMu2ADBNQAScTxSw6AXy2lVwFwCCCJmAHcKo
0nf2mEufwLUI8eIDcCoDkbaKmYAMTcsXmdhT9SgFcljQfFcIbOvvA/jahiYzHMyFoh1w8mDRQ98T
5L6joOa68mXbmlv9sk8VlOolIzkkvTSyKf7ZGYqPUqxkpHj0ZHDBjpI3AibiUbuqtdlxEiXc7oKI
7N+vzeu+EAwsC5zwzVwOgtO3xquViJs8SeUJiR17Zq8aAOxwyF3IZcBOngHlmPKMdyF1+tzpND2C
FRJw4vrAtDv2JOnrszdlL8fIkuU8x4RYPFtXB5SIkQSrWINBCGHeVvYa4NdDITDLbJ67D31+K014
TMQkIgnOBX7dFZCdEoHERGRbm2Jcw20ww31y3iiZLL+4KPXtY0Kv7WyG+M0gIIVOrpCAVW8an96v
U4dsToZ0t/W6QlNzWM2aGcfPsE7zG8J/gwGvO/Wbw1j4GAia5knW9JT2zNfUjmTnoWJV31QVH15c
JHGu5BfoJodrtSKYHIyF15GJuYz3CTkyKkmu/21ZShnwdI+gekJe1BF+UmDGbLnmSsi4ZuY9gkmf
Peri8Xy485jOKxQqHZ+e3sV1Bz8W7ohaGUVBhvicB3Y9ikekZGj63rtv4lMm21ymMuT6XLAuB99W
TJqoE6kGNwK4ugD4HYf+I6w9k670YU1J9rtbUVo5fXnudCRbIZ3ECISmYii2I0hPMFhIEB6OfoW2
ByN38rC6kbhHdZDwznomvGj+AonaxPXGIeSR1xRZcIZ+cFD42n6/uDkmcPS4Ukd1EzW+II0F5U0M
p2Nnr3cU8CGKHWZEIFNVHnn7bz18/Oi3vlYJyg/dvMjFYQfI1sPJMhVFwbquv9medwTx7ofEAR0q
RZ3mCl+vPuo7u9Pr8yBkbAhQNe6H0yZL5KG4z/r2QPcEQ8DuhbtlvqnhGSuQOOT3OC76DEU5o1mQ
64Oh3QQ9VnyQo6pZo7ywDsSxPxSqcoySS9MYXx1CVddD3gsUhTcCfJFzDIiISc+FaCHELSUPY8io
aFkWy5XdxmzlMj5nlWnU13ncMi+AYCeqML9K3cqhU4rCYNQDRIaKqz/OD09U+EMBrQ1Rk3EKbkzy
KBcqP2Oga+D1sOL53pjbKCACK6Rr19N4OU79IatHQx6eXmqnxBRtgNnJwH0pVveitroPSWKzvJ7l
YrMURgoTDmD4hHSk8HeKBQuiRa+sf22f0acrcChcz9TYcEMACk2SuNEAQ65hRR0RE734upny8HMj
sz+qVca7OgiPwGlghv22dNOgslBFQjroMMPhuls/Ut59qhEfizf52cL7IF8GHOjdousA8TlwVthD
IObCstiUxXc3HToFSfnov5C9HLCtDiMhN04oBSwfmFToidnNyrdAyjGejbUUnTQt5mtL8aG1ED0Y
AsEVwco8NG8QtNME+kfVkBUKqCnHGK8rEsJ2fM4iy4q/3w7vowuA5xAJKCFuNrd2qaiNDi+jtg0J
AqoE8G0cVO7TuZkRe5qLEyRkIBhQuJX+a4pujwbDiWUc4VqkTDESDIoWA5D5XuimDextH+dwQ1a5
QGVE2Ii1w8V7PR36gyrsJo2Pn5rfrVasXtxLo89QcZGs6BgGCOAEWyNdY7eKAuBx+8SUSybVQjT4
SV4G1eGsMstaKISte8+JDgmLB5nixBU2FKz/iMBwgvYJei4FWSiu3Mf7Wyk8xoOWOmDPmvwu5k8T
b8vhjeBIRbzbDu8oylgT7FGP3dIKnnuZI1Toqh4NBfJiPHxjV05qmk520Gb1FkLOMXH9L1xPgA3J
9JlDBkDZ1Kf4XvHz+Sg8BioqecpC4+A2vcacY8boiJwTVdK9RwDP8cG/5YAl8plZV9qLne+o/Z+z
JKu/hv/hF/YGD0c0OwmnVlzXYUlSF3OXkaxJeU0uxJqgVcGKXcf2DkrCeMWpzvnlKGRZZ2zj8cK5
KA36bOyWk2hEJeK/XmzqDc4Q8JKc9FjQpOZPpu0HnSNs2u9WyvFuEKLMuQfUndfzlNynaJdJkaTf
JU5+zC3pskNh2uoeCLSMArbfxU6dTYw8mltBlwqulR49UTOjimS9whZHRnPVdkYIfOdxH6AhaOMn
OgF4YeRFz7tC8kFvpBphRiQgiQCV72utqxAP7Ti3THnGMmKKVIj4NMfEItTjyCQcwicttelBtXJT
ozqE865RrZhabiIYb95UywHb4xQlvVsH4PkeAQzbUJQCOex6EeZYi5stbjjAcEB6EACd0ToVDUg/
f2ctWRQq3IbpSl6gJcPhsaKDnPSqGVec7VGi0YmpVxu2VqlnSDLIy2Qk5qL68S4Hvxr/WH0oJ/vc
aoiLPAuJM3sUc0ZNtiSBLIIxNfQSmPfOCRbF2Cxr4wAAQmBJREFU4aLyzPHgiMzxRIaj2ahzZyTr
UVG2lzQEVrVGZ7Bfj0YvDiT2BcC0yErHEtiyNfJGLF/10neCOLpirMPWxPPiwwqRm+juGNfW6MzE
OATJnwIoKI+oYb9YaC7XksDX7oe544/3eDyHBSoUpKSLHYSwUgke7CQHqnq6Q3++2uogMQJY1owQ
c2yPfIFJ52aDA4QT83biV4V3knRZ6Gce/xHMVyHeFPj5B0QFsaWAvx5gAE/Qcbbd9aMT3Drv9uDW
Z0kmEjLf131zaK/CGFleD+NqYsy9lAat6jTAVDYbMveili8YZqBqYDdYHSU8SUXNEh3/YjcUX5xD
4QmQJ2jADr02Eid1Lks0bb5mo/sWgxbU58JWJKjwiZCLajlUdoor0Rho0XB85g5I88VYQLnFdShO
woyOLPkwjiuHhN4EyWeYkAVD8ebxsIDpX0CobrxIjmwq56k8oGLwCK9jYgk0usrj+7Qswwtiou0x
Q5H4fkQ75cI/ISnTgXTyoZ4TntULWV58fxNgk0QOEsSTj7N12U5MNrEfBj/sJAPuU6xtbEHooS/c
lHFwhgLLacjGK6OVOJAZE6631dbrQskLaiZZmgtaYl6McnT9eGY5sN2WpV6XvaVx60YALhVq7IbI
FjTquU8WB4n9G+a20Uls7UqiThxiglEoL9q4Ht3lnGwxZecf4xhQq1dIEuZqNneLhefLRMd+tLAu
i/WI8q+Wu/K4r+0kk+tTuLOq7kt1vWSegkoKLECSKE78OVJtM+jf2Bgp6vYrSrKNnhBl2p2h7PUX
Lp6Y43yNK89gsznc4yQ6g+kKE7ucRckqxGeZRlLSwZFcNhdOpdJeUKWibQtTXYnCZEgtWuFFJ38i
H6yxeDofCQVzeU8JufFkeKMFploPVyvvXkDs46sOIpwHxMxhplqUq/QvyP7a2cRsNeHRPCNNgqfi
2HmtLopYRZVIzASJOMe4TwwjokNkaEbiO4CiCNiuiQ9ZzLnzaF2RpzVdY8KvF4XlbYtbtwXAzRk/
OnBXKffhDibst4h8B8NonrGFg57gwWVhopZA3ZoGELpDFAkwqg3S1xLiG5HOUoLOGte1a5zOMTHR
63BxDvNdQlY8QOH1gATyEpJUcTRRkw5eZ7rj8mQyWBR2I3JQvD9efzb37IqncyIEFGlPXiJBvpHg
JTCnKzHNmFAX/eeTyQlzX7efsnb6Q1teyZahBxdmvwn5kOaj+nwjOSmN4tcyYTB+YB29RYPBrcAX
dnlZfNA9CpfF2bECELQESFyN+K7qz9yebXWsIyIra2uWiID6fpAOAKgD58u+HoaH+v2Kh2yBmsbm
hQiO8OqjJYtjN0+KW6Prx7RrwyQvEtQfrjVS0jNRfVRzZC8GXAhyz0biout9zijL7QMEbtkIIELw
633DDUc3KmMLGgShft957DAbRYRSUwUqUcKY3Dq5OOtt8yxnoZPkhCiOiPMqVixFT7j0JdcxzFuv
xCw4IarjCimK1W+EE8u/V0gYcYfi4uegzaZnAZS9ctPz72CpU68W0wr3OXBHpAiDLG5gotWuUKvv
lVqCUKGAQPa06fIzNmvDvdjXr4wqZFQyfU+ROjR10aPxTuwKpfOE1eq9Y4zkJVq9dbVTbZ85bDMb
TWCaZ3zqPp65JkirlzganO3lA8ZeQkZJEr8TqCw9D/HgPUxAxpkQGWVzm4q6ef2M4zQ+TIMZV3+T
mGNwu2cAt3cEkJLWYoI0caU/BYriiWv1PE8PfqA+pWIW8b204CegjdG3VC7XpemNI5ipDKESTx7t
IQPSCGDySX25dquD2Ona/AWfyb0OqFm7x/i/dL8btLoGm+WUQp7xlMywHCCQcUbFyt7mvqgJdlaU
KTOTohlpMR96Tgx199z9W5rHYn4fpneb16J8krydDvyiWEQ4mHQMgKyl4C7jnwg92w192nmTT6gZ
wo4v3kdsCJLX/gg22QYwZFfNfMwWSaxaD2TGeiUFTPfiayGtnZRH9tKjQkWnIETP2paaf7hPPisE
zreQs+ZifpVnxqwoXZLYASazQZwgdncB8DyNAgLbGdNkrR1gNWUymn9agpUVvioebG3FxDPcMX9A
RwUfelZh5MdDelvnKdXGZrN+eewrLmDq1uboQJrClIYcufveu5cooUGrYYZiZW7A/PvdQpw5nq77
c1WkDocqYJR+py+jMA3PG3Z6dxW6Ss+2p0ZmktScIPPt8ZyNTG1HD9sKe3UtulCMJmLZJv/db2AR
hVP/DCVY1jodJQ/GmdgaJ0mjgWbXTea6+E1eER4r+kzQCnMrYgjHQEaf1znmemvBKte/Tck0oiNB
0nsbvyFcE5+ba5TVZ+GrId2122+v2664O7w6uycHDzNbChnmHZTilsWtVAKs6bOBcZ0qfaduYDyL
CCpq+oLVlbab5b4OWvOvg+y4qTIU9ZwU/8Fz2WC6nbzqJ8IwM+0VqDtcod1NL7xlOkSCosHKXgNJ
XLcIllGkhRvizutfPCMH06w3bkLQRBDWMaKSnReKdJ4HBwkCrA5v6lCLmaehOMj3q6QValTxoWo+
vDcCUDe9SGCLssimK1RmWT89qlsW3vKYlNP8c+Vzp1W2iKhgI9c6Zo0pRJgoEubyZ5TtLhm3eS7e
o7d9+rZOOcbjs2lccDOHZdJ2RNJn3PAx2XBIOQa8CltNdhKEEmR+j+OAZCEW1TrjthGMt6jEFJNQ
EmC6QWUqz1E801xM8rVUqXF6VcNzvhX6UYOooGHR+ijyM58EmoKhWyMAz3MJgNMdG09nZZAkXYOn
ihm8ozvtpVHb8Xiwiw2/V5Wt6OGPx8iy0Ow/Kl0RIVEFf3Ya9+27zMa8kgDjyqDoFhGxLsl3CvFw
dE1Ia5pAdZB43XCUbPe8EuUQRCHthod94dAlx3/eVkjDxkWV6zfI0nQnOjwPQbt82t0q3A6B1YWU
ku6FqCfC/LiDPpmUBqk3tx0UYQeuVTiJikYMYuFW5Lldb0QYkgCOi092VB50EZSCjjRcrzmfOGl8
4JZWyTDFHoTpdjNQLDzvxfPsCj66KPYhZZayTA3mOdufdS46GBljsqn5uu7rSVhn8zlIvgh10ZMW
dSdqnZVZWSxIvHBEZa2RWvUPwcsBEGVLmx/oeSPMb+VK4K0bAWz63Yj7u+KyRw7srAuNid6FCtGk
+fApnMrzyg3NjN3KF9Op08HYD8aY+a5vQvIc95nrudPLsa0TGo8VeECCDCGHf07cn+Lw0nlgkoaF
rGYSgWzS7WzqeoVRSyzsbWiu1w6KzmhHlE5OMqWgrrmC7KMpUu6MfPteanHKBZkTCzrzK0BiL/lo
8sFkLhUgmRI5jHbALmypsuCCKa55KQy+7VUD6REc+hEsZuPVTCMWBpgfx+QnARlAqYRhTvMF5Rbp
safiFnIUT/hExOcQ1dBtLAFP3NKcY9zKFSAzIQJKjtnyjKdOfCug3PJuvTFp1clHg9G0CmKPoxGS
mcacu1Q+bx66/2TtIdRe4umon4W4mdpOjglfcs0z3kqAz2+QFKhzt23FvjVt9ProgJJCWyHmocQs
Vhr2upp0rfpBs2k9tTxWv2JLqgfD1l0HpEBBWCexEB8vRzQJDPvPWY89Jn5Njk7MaNUf8ELznE06
xEXQWdwndicxcZFU6WaUw88EtGBAZaKKuvBLAJCQw8DXw9PcEUJiC2AVOJepyxldWxv3FzICGhC4
HmxRQxLhmi11kl0REljpx14jQ1YcGHn0w5BvNEAWtMcH8zz6HsSDzUnrwaxyLMoqhnw/3C07Q0ZS
bdiTV837xL+Qebpq1XvE9WQF0ifSxaroSO8dcFS0KwqyYhsiFizJEZ1yTBRDc9YeOKJe5Hi52FFX
wdN2BecYWY8Nuv6zbZYKSxg5ZgAOynXxSMK2akPUZbQZVistIqlVnrl9XgC3iwMQsikKkoqrAU2c
c+n8zGUuGl5UeN6s33b1HWmfOYzijjCn097q+D2+zWldvL4RPqfOLuEqwcvuWPHfR+/vYg02dCSM
lmz/v/McDkJqhHkgv3E3lkhIEAlRj0pfEbuX2Wzc/UeBwkCFSULX4nPj14GKxMIoW7RCTU7iw+Ts
uicaxCVZqeIf6KYC7ZOD3QW3w9BrLpirTgNtVwyoXE1hcBN0SwotgA/c6XoWjil4GUUATfEgSEss
eKUHzhwcF/IfSLlwvI/ynEb5KOV6hM8SW2AI4VYNZhCh8aPwF4KteCxuIau2q9BPVNfLOYZRQ8oB
osFRCepEXHNFJigXbhsbsLhlvyKqvowD8/pSsDrh9j6F30QS7RV/SqXVg1KpuxWqf1zAjgohjsBc
Cp/CRY3unzy3t3Qd8HaNALQzcqO1rHJbhubknpIwLBOkfKdO5UeZ4TZg/kcrBTovHkBIS1rNj5XA
AlkwDqJs1I1GVCQNTIssrpA0wojDy/Y5H35uPB6JhQqpkqHa0/Fpz7CNBrYiYyiLOVDOHRmZAJmS
QJflibGNTZoMwdxpE/JTrQAf1yuR74rks634YUC1A+lwMfDlrb/t2a+U6HxSCQn8O/FLtKwOGUBq
+gHaPTOaA+yjeWb7M+PYSYsrgg3Zb8EsyCxm1fb34vs5jaI2bkdAJiInKGFLyftCiruw0udWsVxO
P+s8KZmtHlsiGsqRvj2s0YCZBX+UbML3LxXyKsmNG67TgXWqPbT8sHpEyWsUxGgg5daIUSmXgVxL
a0nDLgCe7xGALdoFGSCsUydLy8QEJ0ZoPNwsAd+6hz9mRJBdaD7M3HPVXjnx8bqXU0fqCh2LJGf5
wMb94Zh4gtwryyE5qdDlnyWKW8UWwhQ+Dgcpv+iWUvhmQWvFloeQEVlq2fh/r/ey2JTwSaINLBLO
BQHgNT0wTNjPle2pWbqf889h/KTFDQWvxGzAFtPhGlYdU+wc9fNUK1IVaOtWyE6jeF5Ki97xjtB1
AkoFNgjUnG2GoxPi4IiYM4mQCXK6V5e/8DZEE0nuhAyYbgvwu5RRMBOZitjhe9Cw87Ru6CRZ7MlY
ikdtSyrqea6tToECRKX3NDuFjusE2jaJo5tEbDbXN5nuBZUMMMpT8U3Vdyex+1EbYEFQrE3qG8lV
7dZxAG7XCOAMh+uZVFiV8ewbzexPT5BjdYAmTZUyR3hOVK7a477jclWtTyEJiySN+k0mtVD7Mlao
q5wxyQ7Wed6PIDEDF9g6zXeL1bTymMUGF0aoH2w0TMUH9VYVScxYS9yj+pkPgmE1k/a4H17OJwvz
GS97bkrMZDo5kW8O00g6OICZMBQjDDoiyV1gsfVQPMQE/cd1xHjQQbtt+a6FXgaAaVFj0vFyBxls
iksHOWfp6LUkC6u1hRkccwrC801HSVh58yjxbPn9UPlcevaVL1JCFwz7xydC3x2YifKnp5EdbO6N
MMO8VFciH45+XUihVotMKAwVQ8VqcpKSDuMBL4oCWPEi6ceoLdyBmmdQbczSz6MXOLZ4jQA8t/GV
RxefvfLlQh/efKafWP1wF6DMkp1u6twiK9tnwhfyu7OTbvBLD5yDkNGqXf1a5Gfv3S9GGqiBRp6b
1Ym7xgFnH2LSTyZNd/7lmlxdFNsijDqgwuyEo9ByWg4tMwPS5wGhPsU1g5WFRo1ceT1n3D4zZM0y
wKNiBIEd2IVmpy5jJPd0D+fFLuZTLytUDwHLwro2vRaJCV89l4Hw6AniMh6PoSqjMAin1bNZ7uDv
ixHVWwzy7BNf0K9VNOPopdhzd605MeYsUGGTyo0SuPYHiJ29m+QYVAASP+2esbl0FTB0EVKWikhl
eie8JEOXLqq42d2YygdPFEBTjllXrkeJsTxZ/FEXAM9pvHm5vOJuy/W3ovo1JSKbKkQVMhuAGJ9M
zrHJex8Zu6gOg8A4JolYMe+AiBalfFCa7oZX1quD3G2nQTPe/2c75GKFev9H5SYgfAZPl1E7f/d9
jXj1JLeqM1PGdiqCdD4qf2YbcMMscUu87q8qxv7OlZp1zX4c/JOybzTGKbTLVw6Me13g+eQxJoJY
3KRxQY0s22UP0gPslG0E9svCk3qRg9SK9PnLEYlrATNIrlqqediKiHoQrkVvGm3pLH9fpNy4pis6
X6ngquMOxQG2c5wO9GZJtcLsUKwGXqXyiWcn1ZlsdBpzrf4UwQ5Z7cdnHgD7OSa/nxX9pS7erv/d
1ZVffPHx1d/pAuA5jVffuvp/Fsel2pxmuHu9yQsdwHVdW/idh5cf8oJMi4GKcFXM2qw4vKeyr5MH
tTwAvYZPZ7BYlWAoZUZ8Nfy/vRlZbQHshWh3XqebqxsWbUOyGDXa593JqeQAd51Uh1wvAxYMja+d
3Cje9psSAqFnngRbQy6IknuGGtxOlmCZ/LmaAYnXgPtuIeczeGGSbH1HOVYBLOy4MdJfWaqiAsk4
afY8r08XZoZH62aEk6/kiTcOBTtdN1+MnEdTMRLafFQ5hip/z0pYXnW9bvBlej9TjtFXpywbvX6N
ZaXXTuQZ2NxMKjmyqlfI5G549fL5qUanyjFYi/HFzO3Kl4svP7G/1wXAcxq/9srjX3y2+OP1dEeC
+5zm4PVzBLZBrRKSr2eCJ+iYRl+bvke2+SV1PSLxjXUsFMz/+O/S5oBPJlUEl/KKFGgNJi1YZbe7
AKGj/htWo9nZLCWqi8ZDrIKxI5nqJIQsJCNeN+LksK1NecEmcDmc4gHoucCijlmS0SDTRTofSgKk
DDYI3ajdKCewVLDQ5d1+Bb3zfY0jDmDILo+OP+y2kpT01jpr2z0OVLdyHFMhNqwvIFsjdj2rde2M
keQaMlJN/+cSdPZC8p/4GJGyZXWQSo7x4t5Ab1tanchF3VCXDAd/INjlNUvkojmgoHE+TjnGoiV0
XEIMGyimpL1wj83T3B17xlseLaCd9VtCPtYpKsLStEnhzXpoLh6hPi186i2K6xt6tdjFl95cPtcF
wHMaX316+cpiy5XhuA5Qdo1B+Q+s+BXnYitZyCfqZ1Z0jhDCOb0kUeWrgKARukFalflaLCnBmwNR
H31NREN4yIukiF1wAXFBKBzWKEYlSWs/iCcRoarwYy1Fg8zYCSy89w6f/h3bAWL4xLDEgo8URDJd
knuk2gvx+UFBxBzjIKe1TKs2OJw5IYCOTHJH5lZIVdP6YVjJ88nsWFEtlaglNbeoJRDawVjQ0XMw
KjoPEsX5niANoiAHVzzoXHwEGLVi7Q3D2NRh33cuWhCfjRs8SyDHoMLMyvPh5F7fQ53XrXXYkKjw
+PjSffQpzB5RJxS14z5uMvoFKegRDupAKBW4rngvPSG0PNmiOx/uBc3mw5jXaHwQfRDSNU5Kjqya
SMXmAfZ0wVuf+uqzv90FwHMav/qlx7968cweGQ4Gx8KvaWZpx90xpym6pReLdajjPh3Tnz1UlpWs
rU4InA69hTsZr+Et38WvnIhEG/KIayg5dijRCnW7CnGfTvFHi3y4G3n5hZdYHOg8w7/r4cgKaNrZ
gXPV0UQJJ6DrbSVLeAWVcRNMGSQq8OMzIDypnsVEQ0Y8XPIk57nY7mv+ismbSwF+hj3M7xGhgPg5
iwODxy/H/x71E4KHARddboxBZXOX+DvgWXrbU2em3BleI/QwYyD6gZzOSGWEjRVhYJMAdVVs3NEj
qD0SsoJgfN7zmG2YdF//UXWusVQUEvdHm5RJjtme9DDzNxsGZHkk4zK9dxFHih03Qp6BFAQWxoNx
y1AkMcPshDwjzE+C9bBqu8nJ9TL6cazlJgqm9sgxAwFyx3I9B1ie/Mab/oUuAJ7T+NRX3vqNS/en
0fXBw+qaqw42GGzlBmAyb0qCdk5jOF4VRGVfQymSu06kh9eLOXZp60kd9/gNvC42zINc9AphqGe0
LiScas9/Mipx8xJwnmbP7aDkdUGXpM7jFkR2ogjCBGSCOrHw8xWVcU4+o5vIDmcoMBMVFlH1wviZ
fLLLrp4G7rqdEEmj4Xs5z9ujESafY8jQp9XkS6S0abxvblLomFLqkCyhLULZxahtS84yf6fPsBaL
ntnhJIsMLfV0ZBOuJykl3tTO10hfwMUrouKcuKm5VKEDIuqC25YG9pZPcyG1GUCJ4iPlDK+Up8Du
PSVfKchZb+qZTmuR1ZgQhYCPBwRp3A4hcsMSgXduwIwJUTMLcBEK45a4TIu72cHs0g9Pf/XVZy/f
pjPzVukAfOILb7xxtfgzO4ddPV2WAyBr8chdRlqdl9mwzobckoZA4rAFp8FcXhxnuYuTdLGShyJ0
vj2MyyJwls1pu9u8/7j+YwttGWst7V5oso+muBT4IT2FsENu0cJT/OtRVFK7oD0KUjk5qlmW6w2d
h5LKFPGGG9uf2tCJ59WnkMaWdUd8YawDPGf0YuZOxY50HtuTg5xsuQY5/i532pdH8IxwEt7Raxd3
x30q+VtZ7EacNuukoCAjrvcweD3Eg5YVrTapZhJukrcNYwEzfQhff5dXQzsQYAxd84yrjNDtgskK
57J6NLCWQSxdfImaCGNdWHMM2457IBqjGFFYfj7C3xs5BjpzSJPw8Ud847tCd+/hE9Q+7/4nlCO6
S7oU1dv756WV+Ya+HYb6JoJVMkH9UfJbSJE1A2PwKBDWuJ1lPg0HLHZmdrX4s098+eKNRgCe01jc
7Pf9N5/63k+//MZPnT+4c/fyanmS31gmO6lKWyLUQJfvjCG+WByA534Ffen6n5foUx86QvfwAiMl
QAA7AKQP3+6UxJz0xEyUxN2NxTZSB+pJRWvTJo8oieySe2ShyceeO/eFDkJNYOK8fbJxUMknezV8
lUPGBJKPnbKLOICLsRCiS5rL4Y+puT1D7eLPEK8bErgcRxpxJh/QnHASbYmXZGlH9zm9jsRkY2Io
MDptF2dIT12VZ+M6F1e+E9K/TkqV880YJMoCAqIR8a4B90dRSkVp2Cmr6LKTDSbyZgopM4KIaTzX
rkZXxqQ6BEQLyFlgfeYXnsVHoqSr7Tm7DouPQvF+Es0B08OfzJo8W1fHFdYo35/wI5F33z4AxGZY
Nn18ZxVnReacXFpHQb3+istLe3J2D3c/8+VnP/X7/vr/+73LLVMDvlUIwAFmv/Xms+XR06svueHS
gUWhx9WOU31XtMt1qsAtQGhxIB4xV4jmuMtxEg9y1piJVXKZ1dYDEZioEY45b3S/iwptdCCm7lOT
qSckRJ3Z8qulY46wTeH5zN2+h7ykKPbrUwftoVtU1rhVks2hexSzGgsdqbtID8NK50DItaLiTOF/
gsqX2sk9OpyI2ZLO0IcFcdwiOdSA8MacHOORpFpXHWziqBYJaYnYT8p045Cz2O1uIi+sgjlXrCuA
oMLMwIv6Mr8WLgqYHkST2MjHpGiCrPCxDLWnFb7R4YYNPVOJX99Gce6DBKGjnOhmt/FyCina8jy1
QRYtKX3JxhcKOxKOGd8XGmsJMTYKcNVbCfkANmfvCsiWQ5YJppJ+ivix+Ga1VoryuYLIRzpsWdwu
Hz5ZvvRbby3L4QgANgLwHBcBH3zP3Q8d7uLcrwZGC+EBkBVrKegBJpa5umfVHQlMGLDJ7TzkZkzQ
Cc8yqhAxokSP0fwoEq7RrpcgX897yhXZp3qpuTNF0VGASWtBb2EKrkZmtsy0Z2I6e/oNgxiXd7xp
pcoFigVPGYUzGmbSSI5v0buAi8jKqjZUhKEgcBmPj67eZW4avc09cQEMsEpWCJEz4V4ftuF5SePU
9JFdxKp49ENAvMDQN8+nAzMpRWvcGVWJpFHnL+GijIS1GBXvepN3kImEcX6PnAswDmJXh8sI8rii
iiFnaFMin3XHtmuM8lW9jIQDIQx64/s3ecm2WsqzkA7lGC+kuyPCFce00QbaJvK9yCO0aIduVsu2
V2JEMSdurqxCEHH35XDXzj/40uFDh1toCHjbzIAMgP3Y3/j7P/Tpzz/88Pk77tzfxgAEuRUkn2Lt
jxj9MFJai65UMdkQqrmfy3jubEWWnUGiyoqTEgOV6Hgw0SA5ZLAsZ81stgxj+x47F+JImNfnYk4i
cp4kIV3BIjh+ZiUHo8l43Ce+Jv5BOAwMt+/pomNmBFHMkRVJKjPa7DLriX0wPnzE3tWrDxtGShHq
tjASmKqgVeQ6HRvFUhSVSY2gN6VHwc59JBRjByPXw94s7fXr9yOmRjCKSa6Z1ZhI1jLjvydfjaJE
dZPrJFOQuHqoTQCNBsOGjd8kx5CKoRzGMxlTz+XXQA0nuUFWkdeDXlUE52LsC3toeIV18AOp3CXO
MeMzVcTg6natH/3iyp+c38P9T//msw//2C88+iHY7TMEvF0FwBEB+GufffULn/ni44/Z3YNdmV2U
kHUxgqYddU2C+oBMobjrndFC5l/eO79R6wOvZUNTWa6cwPREo1Ta4uSGLJPrVrr81eltOnJjzfMb
fXEwCuOnChMr+QQ0hlHBo5kvxAn3T+JtqPscdaCB1FbUC4RmbJwJmyn9lM8AikNI9Rlmrr/bdyi9
ggchkQrjiVw+VDwZCt0LFwKnn52sl1G1oZWc8YRMqjOoGz6OKEH2XF2XOSbdUs8iRaiWSvfhfjtY
kWcYsk/bDpOnmXMM6xhUjyFmrNHi02aCtAqMuRCh59Ux+MHKT7V/LWhSfC5AGhnhZ13YHdhnXnn2
sb/260+/cMBv4+d3AfAPPu6ewT7w3nvfc7hzOMfVcAbYqlj39IDOEnXaV5f9Y5J+9aJI3cE43USc
ZbkmCDqQxDNOleeY/ScSJQIloLnNa/3bdBY9/VOBpRtXsthEyYXBM/+6njpFN2kz686nglrS9cmn
SDlvtp2awU3so6Urcq+rFZw+5zdmttMg68gJEWCGntV6vW7vKYJul7hSPnnGrE+Ner0jzIhdpTej
4NIeATDK3tps5p9Xdj15LNYPONSONxAly9tZNQoVqiDPWD3L1uInyGn7ZASwSCF9QvjHpea9zjMm
QlF+6jTPhVVlrOOeno8qL+FkjrGN7l8TEplQ6JRnhKc0zRGTNU+2PT4c7hzOP/DS2ffcvZUn5S0s
ANzNLhezn/nc63/p5d968xN252DLlV/Gp5JkXORly3v3+cCMkFMEtjwsqGfGvFSdK1SGE3YnZGs6
TiN4TCzOL3t6p7H7AiCyEg1MTsCJUYTz9YyqalnzG8aTYh9db8qiou4HmmTUTbJXBxq2LmcjD24C
MNXVCTNd5LM9CrBEuNEQJV34MHE6CGZp1RMUPK4ntF2c35rY0YekXIqlFM+m0wz4wKObOOKQFUI6
4ObL2enepiTs1f0TJgZMFBVVAtvTCMCL4s3DQZPujLp9AmEqrp71XjWjhATFYncT+4kW3MjkUMiY
J3XUbiLZxD93FbQxOBmSpc8f1jLdlkFm9rUmUZ8AuQazZkB0V2Bea1mnXeo9pMfJwdE1Nxc/tlTK
TqRdo/Hupdvl4Rz28qvPPvEzv3Hxly799sH/ZmZnt+0LLW52787BfuZzr3/uH3/3vYvf/3ve/y++
9fDpw/Mz3Iep7SXIf50r+8JmVbzcSTAlHKIQi9r8oDsrshWSnJhAaQiiN4Cq2oG4CSxyyQnbUOoj
hkRgpKlPmuzrRgDAcDNATTqwB+ehVEj3bccfeROh6tDTAYTCzxG8Zy2bBy6zdReoXje9fI6OlmOf
LJXs6d5GpT5EiiRytx1zF8D3JHap8+Q8OZRN/Bkw8ZTwkYihUtJu+RmAJcMhcn07gUJFXZ+ESYRr
5gmnSLWRXCtXB2FWyVzfqTU/mJn6c1LhtZa4UJ+Pa20C9fhIhb7z3Fp32POcOwhSAcT30DHMyDOy
BaEjjGjKFNaaLeQHxEKz0AeJXCsvck70INnW8UyVV0PtRNcmNGA6/59MBetnipFMzTEXy/Lw3jfc
femvfvLxv/9v/NIbf/3eGexiaQTg66YIuHOAPbr0h48ePvnS+eFwbutKoEBqLg9B9MtO6XwK8wex
igreNG4hk9Keudi+hKSydXHaUsU9bmP/7W00IYYcBZvLRbM9QrKUeDzpqh5JZMP4xYOiF0PPIGgv
dvSMlC6kFT8YxUzSIq+DCVQJEi/zoWUildbY+wW3intjG5NF6mLXHyaqbwnqhvyV+IGh6HbYrV/K
EdXUx0FQiCgl7UECOzo8ku4FZFzr8c9DzhoPSogezCI9mR65Hf3Wl2XOT1jXxZQzgJzILesNJg+F
kehD8X2IBXUe/7nMV7bVtajitwlfjReccoxfd+BDL8KtqEMV9uHiIiJOB5Z23H7mXo7ZRKNYDHv8
bAuywNXKpecc43PHP9Nc6vysst6KZ152bIYCKOBRphnye6zYgEo5xkPDF6cJgawIW+xg5w8fXX7p
0aU/vHMgP9BGAJ73uFrc7p4d7Kf+3mufvXu1/PIPfs/7//Wnb1y8fn5+uG8Thz2P5h8yG6T9ZWTV
LoTZE6KevBhRuMfe1xnsIgMgpEMXmCBmJnvE4D9RdabjOwZNDWDfDjgdsc5Tg6LT0h8SRXO2vfsh
/E3XnCHMkSzo9xwOgijwXv3aGVXj+QwZhm4FNcfIBAmJncO+vfI6SsJYdZKeCTosFYbycOULmgVj
v+3YJRVyw+mMgSFdM945Rwmlso4+VOMSOh8X9cu4J3848J+teCVknYtU8TgpSYKewcFCx1Ejgd91
Zi+iVJIcz+vwLdCOugRYEFFDVpjUejGutFX3KUoiD3EbZbdj5BlXoXG+bwiCCCy3PJ7BqAkSyx4r
clWNgHFThQivD3vdNBqcZZ1oMOQlCgiTvd2QY9iQaxuHaZ4JkxwY7K2r5fUX3nX20n/4tx790X/v
f3v003cPsKdXfisLgHO75XF+dji3s1ExJ2gWkP7By7RnlWpWTHHBZQ2GUvpWIfQgqTaq0tj2Wd7T
VawNEcv3Ue3jgNIYZHzGzfmEDwbVP0gkNg+rdSHx02w4ZKpNnCND85TvAwaLqA5GJVOW0yWMOAj4
KLIS0t74vUcyFA4Y6owRGpX1/rTWZlw4ZctTF2GlPLxHxYq2IENL3sRWiEkFjoMQC/UZdFVhikUB
VLvAC293pO48rlip9sH4/b5tRLjsatcHPyz9IeMvTsUuPWeeXN6ur+NS/JyCCKZ/l8huavFstNa+
ii6pBBhwYsQxuQ7pdfdiv915zRKeR0Ixd1Ge8SEkNV3xcyf3xmHsExqmJKom0L+sI0AzYhyNJiQh
FCAu941nYCIChCLHrDdsMZZA5hHT4fh77hxu//l4dlu/2NXidu/8YJ/4zUd//9XXLn7qD//e9//o
1VuXT88PuIsp69WzVnw4kCGdCMOfSGgekOdNbsfD2XzHdJPFRqhSDRBjuT4Fo+NSmx1TxEGTvw6e
MdEaC0pK2xjArZi/q698wBCcCZag5CPzYaAuvOQzjr3+rDfA+IUFljHGiAD5nAAd2DlZwywl/a3n
2qDlPI6pPRBE6W8m4+bRNY27NSIVBmxjzEtRQkpbtxsKOeInbD8N270i5cUjUS6aJ0XnPQ869bBq
2OuEhGUQJjC9zZMFrpUHqVys2I6rpXN4zjyhEEZbICiek6QcuuMXaF4w5WX0ZnSguWXjMkYtr0do
h62oNaLcmhUDHlHXzKx9WAHtJalzIy5VelQhxZJNYbgC/7fN98LEZniWD2JR7s6jLTjnGXm07enV
8ujsnefn/+5HHn7/f/Hpx79gBru4pd3/reUAxIfh4dMr/8obF6/eeeH8wZNn/mYUidED1zRJeoau
fZu7s8I46WyvsF7gGKDqLkKn5DrDJngYpBi2TWERZrRrw7g4S7CazZkwATamFa6IlsSZMf1D4ehl
ll33wv99vca0GsPUn0dn+zr3N1OSuXqNOe3Cc3c9YFAgwo/S8Vu9KQgROtGFi8SAV7QirYag8AfY
z4ep3RJlR6iF8vq9xc8g+T2InLQKI7lD0IDwznhcEfU8py06e2LXR71qmdnHmX/k9pOKpE+MarYD
+zBm5TqbL9UtXbYmIlkzckmMkIDxfrq55YdBb71RFx59JdgyV7c93DMfYRtTRoOc7UGPlrizcUd+
frc/HUjB1zlmqfk3kzUTFLSZkVtc3BT9qBniWd0q5ZgyfZAEt+28S/SuH4vfq8Uf34E9ePmNq996
eOE+kUhqBODrIRY3u3MG+/Ljy4cXb15+/Ad//zf9iacPLx6fH3BHOcPl8yzi8tvckv25yu0ScK9J
feFKduOK2plnFzzf4fGAcmH/BzY0jRF0nMxiOjO5zFlhrhsU5X83o25F6Vmq/hcd4ZwMimdjGn2H
nZM0zUi1O3ZDUfgluV4UY3g6hTwpi1Vuh5FUN2XVp2PfEz+kLCQCazrN+bWzjXoARZExOlpBUZJD
7ES7zcMZQ+8HGJIVxn8cB9A30FHJrA4yRtHcKnOv9ccJK98ymVAZ/vGgSRB9rDWNuRj6LmhR7y54
TWT8R9U60SFI90dHUZY5EIlsW9Af4nhhM8Upckl8V/MmQyweqxyj2JSXz1XMrzpyjOO8mQ0y4p9H
5EWBxMjy5tT19376zB89+MZ77/mJjz38I3/l15/83Ysr82fuXQB8PaMAZmavP73yT3zhjc8tz5aP
fegD7/wXsCyHAw5nZNUq9tGoTrYAqMoabahSB2ll5gGgkDat2iGSdaKVppMPfcK2kY9InbNS71Qc
5tEFy6nXcuZIRIIaMqQHsFM9BJJXuDAmtgScFlA7UnEjiaVifKdVSHaFQzHh4L0wnx6ipmOfwDAu
nyXL3Xy2UFXt8+J6oAJ2LUuhaqIuupphHoNSlwmp9BpPmSt5FhlPHsVAto9lrwic0MCqd8/TM+WM
bsS1QRe4f33PULyX8VWD0jLS8+T1OyXvXYSkKfkUnAS4y/poGLVt+YLLeQIARMSJ1u0QZ+uWVvGQ
RkV75D9LZWKlArnRTif/rewwYlEQnrOyYYmbLF4US1BDreufeeV2sZzb0//olx/98E/8ypv/y6tP
r2/GcptP/9s8Aljjys3unx/s0bPF/8IvfvEj999x993LYpd+3KeqhKKyY9asT8hkHLes360vBLAH
YFli1ft0Jhf+DPseCgTrbDGLevpcfVOPQ0sSPEFpRoTypY5rlF5pt+6So+Yh+gnYuY/FT9wShyjt
ZSz59GciPYfZlXUdW+gFwE4xy8BydIlDMVKqkQNFt5D4LOOd8MKDPhvQDOKZJx5LJAmWhxtQfDSf
vhbVxfS9E8nHOq9bHi+VcuByuJf6Dl7/3XTZw3VzX/ImLWZ/cQZth4Jmfd68QC1tvhtfeYDoLR55
Ru7ZsuRHisinS2maMddMxHiqabuZR1QuRd9+9kQwx0oQZoECXhv+LFd+ef/B2bv/y199/NFHz9zv
n12fHbc9DvY2iIsrt/MD7Pz8gJ/82Bd+9M798we+2HJdBCDmNl7Dxiwn4XqsiBNva8EQL6bnZEdc
qqR5hNSnG676FiWRH5pH6l5v+jHD5W7XbtWDcKBzoUIz1yVunevcNO/vOp9GNV8oXutSUhiURHIv
pFyDwgMBaQ0gdeu7UrZ6jV3vEEQDHTJCqL64l/97e872tH9U6IjGMihLrPIxLz5CGt7MkITkpeEM
y7vtqNMyPydKAOOU6FES2QrFzAET2WZLWgh64FTmYtVbuT6r7saqNpMioDJQouohwvbG5MAqM7jp
nD9vpXyt7ow5z8Svukx8DoxJtZOCQ1FVroJqR0lfuBHjhsOH5sH4fYsvtty5hwc/+Xfe/NHzM+Ac
ditFf952IwCGa2GvPblcPvx/vfYr/9h77r36e7/1xR+GO8xtwREfTxL8op9a2YIqpA6X2bJ4ZNML
EGZ/1Sw6+p3H+RYnL/CurXQCkXmtzl+YVNTlAREuUNx9H2vVzrC87JtbgN9Y98Dn44iUM3yQ1IrC
qqrZIFBo6urCyIYhaBRwby01mn/PyGruhYKdPGjVkCOL8CHdr9n5WF63AhLJ4yEWRsprWqBVszhf
1rHDSrJUBz4XX/moeZEKKx09peO7gJthpYlOdogrkG331J5rv4iyTPJcsIWxgW6D5ByD+v2Too9z
TP7sOCDXVfLwkaxCmWMKZGP93sV1o/olPht0X3TvxXOKBXfqjrjtBHrvoy4CjXFFQjnnGBU5woKD
HXDncPjLv/bWn/pXP/rwv3r9whfg9kP/b6sCYH1EzmB2doD91c+8+re//5tffPGD73vhQ9dE+ONi
6PZSxDkln9dIx5SngqFcEXNn6dMgVJOMa+IGmEqtbhKsMzJithMGoga/6qfnA1aPSk3QsDyfzt+F
jv7AurfU4RL3QdbA9aAaf55+sPDcNFE7rQWZHYnhUWzFwnrQio5UxD7LZERERaUd/BrgT0P1ZeQy
eGgqK9ZWlYGrQ9HZ/pWEfiL73niGG+ejTuzt4JtuUfQqEPJERpoStokYVJxtoyqwVCoZ5U455Npv
JDU99L3yqDiiaz6Bzl0OwF1wobgXcSUyfG/OMaovMKFcSo5RHoWHQiDyF4DCRGnLMW5VVuN8gB21
RjO1PIiFv6dVRKdcSrbcrsJF4fB2S+TIiEaNwlPWHGnseswz7ra4LYdzHOzM7Oc+/+TP/cjPPvyz
54frn3Pl9raJM3sbxYo8nh9g/+2nXvnZH/iWd777O973wvcBBlts2fh30Gp1mKF41tZIHVGC/8vp
l3QzQoiqDsrttUJmy9cosVTO8SBF3Qlqxza6hKCKhkPZkUEg9anZHZEtWZLXih1xkmoOGvPEjvai
awSXEdXmXUrZuusczHU2vYTpfNMJDme1OE5sRKoLJLh4ziUGtbAtfVKc6E47VOSJ6gcEo6YhFRvl
Uom4uiVSKwVc9PmqtkeEqmYmNDok3YYwAkNQedSFejHyiiVv3iaZHHyFtGW89nFdkp7bohlA8Qyn
LlWu21BWlGsyhbgGoQ1FMWcFGqSFjk/GJ/k5d5bkclHfc0ErUH+aJMAT3itFC22npHbdpIj/FpbI
lqsA2hWwnB1wsDPYR15++p//4P/0+r95fjC7Wm6v5G8XACEWNzs/mP3kp1756e//lgcvfsf7H3yf
Xy6LHR22PcHtoyUfiUcgtdX+NtSuxFRNqzMopnSYdpt0EMj8HlX/AYFzqwN/0rOSEQ9C5+L8Qq9J
pzZqUXh9TQwmEp1O4iu6+hR/NyCqgDCG7bF3Bcue3MoWnTIUys2Fmfqd6SgnQcqwGclEu37eDXce
PxXjG9Gu5J15jPVTD6tV+fmJz/rJuVoqSHSEw5KseYuj3EbwyuOetTAQZlBsKBORgvpNY6xjEAXH
+yrPY0K6tBivRxMwp9HTWAG2eUcdVwGDpHW8NRUy5hHBSm9T9R6gUMqUa+aZXwAR6XdBYnTnBnV2
Yn0HYuZ7uV48M4PicQgCwmUkNDbY/zBzu7I7sJ///Ft/fj38Lxd7W8aZvU1jcbMzwP77/+PVn/3O
d9179bv/oRf/6NWz5Yk57HCwA1C9RFx1W+o2Jweq5dWhrM4XHQeZyoyAQCAooWnydh+yq3osYG92
HBXYYmcOaBM9XRV0yx3X9mKHwyzLhnLSy2gChhmQsxiP0RzQss65wI1zMiOrjG2a/ZMRhHZJLrNO
o5l7HEkg2djODlUUGvVlkZV+j6x+gTcTGI5lHwCpHmnunO1ugz69mFnVQyCjMY8IvREBUAlhCOYa
tR4FQ+vRye60loCVKEDlAskIE6b3cUV82CGTn1XYjLTImgjknovZcV7rR6gREucZdg4iVz13egcI
0hc+SbWzb0lzI49uHLJmGdAcHa2pZknUG/EAonk0GvNY5Fz/u8Xtclns4uwu7v7lz771p/74z7/+
H7zdIP8uAOSNv3Kzn/n1h7/8jS+c/fr3/sPv/ePw5fDs2fL47GB3dCF5nBNO8yYBxmgVsIazwYxn
ITZH0RQyw4GKrWjeyAkbk/medqweq2qd15nO7PJMH6o7MEt0O7PZOg8G29bY3WzjCpdDLLqxIXed
kwdBu6Ep9Bj5AVAIMxwR6frmEUDibmDvOCj2udPhhZIPQht/BaKE0GlHXho/w5XvvHag/ME9omYh
Qaf1UVR9N2jcFT0ZdNWvgtD1GScyrMXuMFhYI0hCU7ETBJoBc0h3u9k3eJo5E4GYdvoVel+5CGLM
JLIGNBqqTLxcmgqFG8CSuZFA7MEsx4tnJpk2ea0DoDv7G6G2KmBciaeZ3Jn0UhJCq3bTo6pY8+ez
Z/b4/Bz3Du84O/+Ln3r0r/3Jj7/xX791ZW/7wNv9Apwdi4BvefHu2Te+4/zuv/Jd3/CH//QPf+DD
r/3Goy88ODu86+6dw4sbeeDAh5V7VrhC6dVXke1kLWfWBYxaNysWkl0mY6cuu9nzzxHgfeUARIMd
E6EYtwTaqz88gQti3OHFS+2274ngyZRHDv6QlfK9WMcQyyZUtF67aUc+maFWrnUelRZX6VlfeHZf
FDp8vSE/1veR9+LzZDrK2hkvAn57yJUgmelSVMfUcAk7hlH1dYt+Fp5QEn2mvGSZ0Lf0WLZwQVny
XmboTzys3CdXmjvq6q8Be4ZIkzlH/DWLc9EbDlmUn8pTAWv6riikf8OpjiufgraW8uMci0T+HB6g
dyfnvdiwqNsnJuuRlYBYHC/GZOLm9nTxR0+f2Vff9bvOv+3P/81HP/Lf/d9v/eyXH/vFbz6+ulpz
fxcAb/M4hLWP994/x5/8vt/1T//4D377R80Xe/za09cMsBfODy8B17oJJSlb1ph8lmTCKhuKZOAJ
FrNUBFS1giMbe0TWcxRkmXfEuk0cZ5/Vnya+uLEWb/3SVsx6O3WIxeTmruZs6TORG2M0sXFndUa9
JoD5spSHBcnqFvCqqzZ8uKEucLbvywXle6S/pDxw3WYXcBCuvISuNWlX6EsSv/edzna9NoeByOjz
PlAyJ90IaOFL2vb1u5ffJYiYjKwzUqVaX6zqGXPzm/Ei8sNA9zTZFm+GN7LbH1CK8Swxc9/1vgf+
SOKnVKOuyhFxMiZ0MiTLHtuDse8FxbKGbaLeB6x+qUsX0AIKur5eB3Pz5a3L5eHBze6/eP5uuwv7
sx9/+EP/2a+8+fOrwt/hbbTq1wXADYuAu2ewJ5duL5zB/uXvet8/8r4HZ+/9iX/+d/+iLYtdfPXp
E7+yizvneIADzstu2upq3XdeTiUa8agsHLHOu8YzyJXgZF17inPxKnmSfqrusXuS03VJnNrRDXKW
lxV91b2yl7sVyApb/padWkA0FHGpk5vJDNl21FDGZzBkj55KVjj7tGctgsqKkI1q1E7YpmgC5K94
YgG45YqzEJ86bnuQI3GQSN4KiaOuv8K6dgikVc/dbzrMXYhbyWorz4v1Xu/ZWFtZ5PB/YhRrNUHy
4JZoha03P+/00qOoxNL18lSQ8ojA0/uU2e1ymEqOIYRk9h5GZI6cEhWNkC0br9sHQu52TpzxOSvv
FC0SrNp0NsBsufLLZ26Pz4C75+86u2+A/Ts/99o/9eqlv/Y//Npbv/boyv3+Gexi8T78j3Hel2Cg
b08u3c4Ae+vK7S9+8iv/p5nZC/fO/qBduf2ZP/Rt/6s9OL9vrz21i2fLIz/Y4cztcH6G+1VXVBOD
xkuj1ff6cmPaj1cJyES7PrqqFVWeL8c5nMgOE9zs4wC2QCp0I5c4i0Ctp39jPK7HHHkouhBwpr+G
6VGL4bnkoenhPZszFGfrrB9iY6EgaCfkLtWOiGtjJY1bbvbm/U7XZv5sJXZU9fWK9bYqIUcS3WZa
NfmzvB5oiSzqixSfwWUS9jV+iV0P2HRyT3T1bSt0fDZ9MFm7257/xU5JhOIUqBavl/7fnhXzdCNi
VLE6cqxHJWWH754fO7VgRj7At7W8SMZICqlcGJ66fVF3JI5uksV3gb2sfJKrxZ5c+bLAfLl7fvbi
vZfOXrLHV/bjf/PhHzSY/ceffPOX4rj3yVWf/I0AnLooMLt7ONjV4nZ5fIH+0z/0bT/y0oOzd/9L
3/meP/fgmx68z55eml0u9uytq8cwO9i1yND9eqa9125I9xBOEfegpibe66NaX192OSWL/ezsyxU7
U+fujchQq742DHD2q9fDtzgUV/h8ZopEsHttJybXEhmWdWxe9j7xNp8/+eMLcIJMuxsD0ZC6B5Mu
yGDXEukJfYGV9oypk5wdZDuQaLofBZt/Mj5I4xrI7/Oq2A1HETlXjg0UX+fIAq97EqaawMU+Q5P9
ZhyE0Mluz4dzYW00x49VIa4lZqH6HW7lzTlRvxCMTw9rHr+oKBSjALzOV3cOnsiQ9O6t3beYDiny
SAXF1KxJR0zQIUVJ/uMcw4JSENQNgF1e+ZOjDPly58HhgZ2Z2R3Yo1efvfI/fv7i33r41tVrf/qX
Hn3YzOz8KP72rLv+LgB+Oxfn3vk1oevJcVH0z/yBb/6BP/Cd7/nnnjy6ePRd7733Qx/8wLt+wJ5e
00mvHl9cwA6H4/N7CFf3gAnchvIACDB7wQva5E6FwFUmvoI0Y1P4P9nEK7BOnT1/6IXmil50NdjR
PSeTGcyFT2a2vjsNte2g7CkRlZ3hrGN1SytiJodYfVZXMLRA14USYb6ncvwWRVY1esDEVFXZ5Ibc
McbPSBQ0RSyKDRorEZr6Ro/7hYxEaJUZrtf+jD7O1gtUSg9N4hMwi33a0e4geARyO4/FPBJ6LVUL
k3e8Pon5+yGLa8l3T+JAVMTZiZFY/UyOQ3sprbBn98oZ7Fi2d2uxxdztCr7cuX921+z60P/cFy8+
+umvPvu5+w/OX/yFzz/5n3/8V978qJnZ/aPX69Or223n2wXAP6C4e3a9ZvI0KEb8s9/x0vv+kz/2
HX/hyWsXb7zr3uGb/9FvfvGP2HKUk/JAnnI5MF1JMF54ZWcCVO4O812Mh0b8LXMfraJrFPNw6nxF
uW8iglgmIzoYXNziUqKuTuQgKOMq41rM5MFM5Ko7oqJl7cz8JgVA6p3Hd1mOP+sQTWs8jRECfmNE
/DoJn4Y74pl0mJJ3/AhymJbbGG5S6BlbKU86bi423czrMUtVyo1Z/rSGqK33iOcxGzV5Bkv0/XJm
1I9buutNXBfTikrIKMeTKPaED1HY+86QjooTZDt25HnbQ/DKiqRMOaZS9r/BGETzDEwIkjICgJvZ
4dq2Dtf/+JkvXfyNN57ZF++/8/DOf/sjr//YT7988cr6q+6dXeeDi273uwD4/yPOD+PBfxYeshfv
HPDJP/FdH7m/+Et3D4d3HM4O9+8BL+DM7p65371zdrgL2EEh1HgXcseHMnlRESCHyzzfytrX9q+X
a2nf6TpUhvdOOLRS57g3uh3s8QR/7CS3DMtv/+owEJHZ5yyd44TRvrsypodMhGdHHcKkQtMDWrcJ
YJhlzhOQPZ328f8Mn0U7yMQjsWjOY5vErpOe4OR66DODYsxV3csNOMpiNXtFTPrde/epmCN50c1W
2gJKRtxDIXTynfg903dg2I+WKIt5GD3koZ0W4nBXHWlL2xvT7juQW8PzwAWf6kzONxGSPS8GSmU7
RaSZ2ZX7xdVii8Evny3+ePHD1cXV8ujiyt58Anv43X/llX/m0bPxl+8cxq9+uyr6dQHwO3TxYmPp
bvahb33xnd/9/vvf/u3vuvutv+cbHvyT3/Tg7IPvf8f57/7WF+/+E3fP8eLiYnsaU0Qw9JghkhHa
1R1a7T6mcLasHdbsd+UL6OGxftbFEl0nD1VPdNIDQuaubFZn5I2E+pwe2QjKFszHQ2iyRHa3RB+K
sbQWcKQbMdCIjXORdBb23PASNi+t+2Q+G7t4XV2cJIKkQbA3ugkHTfIuKgtcGUfQMxzWAmdrfmb1
muQNdAiQ2W/T52Gma7HX2WqHXnM9ixGWz9YyGV1iZCD87JX+E8Y2Ooqa1YuQ+XqFItKjJZoe1ZiK
xm1e5ap6u8PNFhzs8JXHV59988Je+erF8vJnX7/6+GsXyyt/95XLT/7vr16+/PEvX7wBeSS71+/o
6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo
6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo
6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo
6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo
6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo
6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo
6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo
6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo
6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo
6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo
6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo
6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo
6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6Ojo6OjoeNvF/wdq/cNiCMh6mwAAAABJRU5E
rkJggg==
B64

# Compile Filer.
echo "Building Filer..."
if ! swiftc -O -swift-version 5 -suppress-warnings -parse-as-library \
  "$WORK/Filer.swift" -o "$APP/Contents/MacOS/$APP_EXECUTABLE"; then
  echo
  echo "Build failed. No installed copy of Filer has been changed."
  exit 1
fi

# Recreate the original Filer icon.
if base64 -D -i "$WORK/icon.b64" -o "$WORK/icon.png" 2>/dev/null; then
  if [[ -s "$WORK/icon.png" ]]; then
    mkdir -p "$WORK/AppIcon.iconset"
    icon_ok=1
    for size in 16 32 128 256 512; do
      if ! sips -z "$size" "$size" "$WORK/icon.png" --out "$WORK/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null 2>&1 || \
         ! sips -z "$((size * 2))" "$((size * 2))" "$WORK/icon.png" --out "$WORK/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null 2>&1; then
        icon_ok=0
        break
      fi
    done
    if [[ "$icon_ok" == "1" ]]; then
      iconutil -c icns "$WORK/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns" >/dev/null 2>&1 || true
    fi
  fi
else
  echo "Warning: the original icon could not be decoded; macOS will use the default app icon."
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
<key>CFBundleName</key><string>${APP_NAME}</string>
<key>CFBundleDisplayName</key><string>${APP_NAME}</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleExecutable</key><string>${APP_EXECUTABLE}</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>${APP_VERSION}</string>
<key>CFBundleShortVersionString</key><string>${APP_VERSION}</string>
<key>LSMinimumSystemVersion</key><string>${MIN_MACOS}</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSDesktopFolderUsageDescription</key><string>Filer needs access to your Desktop folder to show its contents.</string>
<key>NSDocumentsFolderUsageDescription</key><string>Filer needs access to your Documents folder to show its contents.</string>
<key>NSDownloadsFolderUsageDescription</key><string>Filer needs access to your Downloads folder to show its contents.</string>
<key>NSRemovableVolumesUsageDescription</key><string>Filer needs access to external drives to show their contents.</string>
</dict></plist>
PLIST

# Sign the application with its bundle identifier. This is ad-hoc signing only.
codesign --force --sign - --identifier "$BUNDLE_ID" \
  -r="designated => identifier \"$BUNDLE_ID\"" "$APP"
codesign --verify --deep --strict "$APP"

# Stage the app payload for installation into /Applications.
/usr/bin/ditto "$APP" "$PAYLOAD/Applications/Filer.app"

# Installer preflight: quit Filer and preserve older installs as backups.
cat > "$SCRIPTS/preinstall" <<'PREINSTALL'
#!/bin/bash
set -euo pipefail

NEW_BUNDLE_ID="com.filer.app"
LEGACY_BUNDLE_ID="com.local.Filefinder"
STAMP="$(date +%Y%m%d-%H%M%S)-$$"
CONSOLE_USER="$(/usr/bin/stat -f%Su /dev/console 2>/dev/null || true)"
USER_HOME=""
USER_UID=""
USER_GROUP=""

if [[ -n "$CONSOLE_USER" && "$CONSOLE_USER" != "root" && "$CONSOLE_USER" != "_mbsetupuser" ]]; then
  USER_HOME="$(/usr/bin/dscl . -read "/Users/$CONSOLE_USER" NFSHomeDirectory 2>/dev/null | /usr/bin/awk '{print $2}' || true)"
  USER_UID="$(/usr/bin/id -u "$CONSOLE_USER" 2>/dev/null || true)"
  USER_GROUP="$(/usr/bin/id -gn "$CONSOLE_USER" 2>/dev/null || true)"
  if [[ -n "$USER_UID" ]]; then
    for app_id in "$NEW_BUNDLE_ID" "$LEGACY_BUNDLE_ID"; do
      /bin/launchctl asuser "$USER_UID" /usr/bin/osascript \
        -e "tell application id \"$app_id\" to quit" >/dev/null 2>&1 || true
    done
  fi
fi

backup_to_shared() {
  local source="$1"
  if [[ -d "$source" ]]; then
    /bin/mkdir -p "/Users/Shared/Filer Backups"
    local destination="/Users/Shared/Filer Backups/$(/usr/bin/basename "$source").backup-$STAMP"
    /bin/mv "$source" "$destination"
    echo "Filer installer: backed up $source to $destination"
  fi
}

backup_to_user() {
  local source="$1"
  if [[ -d "$source" && -n "$USER_HOME" ]]; then
    local backup_dir="$USER_HOME/Applications/Filer Backups"
    /bin/mkdir -p "$backup_dir"
    local destination="$backup_dir/$(/usr/bin/basename "$source").backup-$STAMP"
    /bin/mv "$source" "$destination"
    if [[ -n "$USER_UID" && -n "$USER_GROUP" ]]; then
      /usr/sbin/chown -R "$USER_UID:$USER_GROUP" "$destination" 2>/dev/null || true
    fi
    echo "Filer installer: backed up $source to $destination"
  fi
}

backup_to_shared "/Applications/Filer.app"
backup_to_shared "/Applications/Filefinder.app"
if [[ -n "$USER_HOME" ]]; then
  backup_to_user "$USER_HOME/Applications/Filer.app"
  backup_to_user "$USER_HOME/Applications/Filefinder.app"
fi
exit 0
PREINSTALL
chmod 755 "$SCRIPTS/preinstall"

# Create a standard macOS Installer package targeting /Applications.
echo "Creating the Filer installer package..."
rm -f "$OUT_PKG"
pkgbuild \
  --root "$PAYLOAD" \
  --identifier "com.filer.installer" \
  --version "$APP_VERSION" \
  --install-location "/" \
  --scripts "$SCRIPTS" \
  --ownership recommended \
  "$OUT_PKG"

if [[ ! -s "$OUT_PKG" ]]; then
  echo "Package creation failed: $OUT_PKG was not created."
  exit 1
fi
/usr/sbin/pkgutil --payload-files "$OUT_PKG" >/dev/null

echo
echo "=================================================="
echo "Filer installer created successfully:"
echo "$OUT_PKG"
echo
echo "Double-click Filer-${APP_VERSION}.pkg to install Filer into /Applications."
echo "The installer backs up older Filer/Filefinder apps before replacing them."
echo "Your saved notes are not removed."
echo "=================================================="
echo
echo "This package uses ad-hoc app signing and is not notarised."
echo "For public distribution, Developer ID signing and Apple notarisation are required."
