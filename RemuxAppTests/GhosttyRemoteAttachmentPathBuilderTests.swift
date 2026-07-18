import XCTest
@testable import Remux

final class GhosttyRemoteAttachmentPathBuilderTests: XCTestCase {
    func testBuildsWorkspaceAndTransferScopedPaths() {
        let workspaceID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let transferID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let sourceID = UUID(uuidString: "99999999-8888-7777-6666-555555555555")!
        let localURL = URL(fileURLWithPath: "/tmp/report.txt")
        let job = GhosttyAttachmentTransferJob(
            workspaceID: workspaceID,
            transferID: transferID,
            sources: [
                GhosttyAttachmentTransferSource(
                    id: sourceID,
                    title: "Report",
                    payload: .file(localURL, filename: "report.txt")
                ),
            ]
        )

        let paths = GhosttyRemoteAttachmentPathBuilder().paths(for: job)

        XCTAssertEqual(paths.count, 1)
        XCTAssertEqual(paths[0].sourceID, sourceID)
        XCTAssertEqual(paths[0].filename, "report.txt")
        XCTAssertEqual(
            paths[0].remoteDirectory,
            ".cache/remux/attachments/11111111-2222-3333-4444-555555555555/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        )
        XCTAssertEqual(
            paths[0].remoteTemporaryPath,
            ".cache/remux/attachments/11111111-2222-3333-4444-555555555555/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/.report.txt.part"
        )
        XCTAssertEqual(
            paths[0].remoteFinalPath,
            ".cache/remux/attachments/11111111-2222-3333-4444-555555555555/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/report.txt"
        )
        XCTAssertEqual(
            paths[0].terminalPath,
            "~/.cache/remux/attachments/11111111-2222-3333-4444-555555555555/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/report.txt"
        )
    }

    func testSanitizesUnsafeFilenames() {
        XCTAssertEqual(
            GhosttyRemoteAttachmentPathBuilder.sanitizedFilename(" ../prod/key\u{0}.pem "),
            "prod_key_.pem"
        )
        XCTAssertEqual(
            GhosttyRemoteAttachmentPathBuilder.sanitizedFilename("////"),
            "attachment"
        )
        XCTAssertEqual(
            GhosttyRemoteAttachmentPathBuilder.sanitizedFilename(".."),
            "attachment"
        )
    }

    func testDeduplicatesFilenamesWithinTransfer() {
        let workspaceID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let transferID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let job = GhosttyAttachmentTransferJob(
            workspaceID: workspaceID,
            transferID: transferID,
            sources: [
                GhosttyAttachmentTransferSource(
                    title: "First",
                    payload: .file(URL(fileURLWithPath: "/tmp/report.txt"), filename: "report.txt")
                ),
                GhosttyAttachmentTransferSource(
                    title: "Second",
                    payload: .file(URL(fileURLWithPath: "/tmp/other.txt"), filename: "report.txt")
                ),
                GhosttyAttachmentTransferSource(
                    title: "Third",
                    payload: .file(URL(fileURLWithPath: "/tmp/other-no-extension"), filename: "README")
                ),
                GhosttyAttachmentTransferSource(
                    title: "Fourth",
                    payload: .file(URL(fileURLWithPath: "/tmp/other-no-extension-2"), filename: "README")
                ),
            ]
        )

        let paths = GhosttyRemoteAttachmentPathBuilder().paths(for: job)

        XCTAssertEqual(paths.map(\.filename), [
            "report.txt",
            "report-2.txt",
            "README",
            "README-2",
        ])
    }

    func testBuildsPathForSecurityScopedFileSources() {
        let workspaceID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let transferID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let sourceID = UUID(uuidString: "99999999-8888-7777-6666-555555555555")!
        let file = GhosttySecurityScopedAttachmentFile(
            bookmarkData: Data([0x01]),
            originalURL: URL(fileURLWithPath: "/tmp/report.pdf"),
            filename: "report.pdf"
        )
        let job = GhosttyAttachmentTransferJob(
            workspaceID: workspaceID,
            transferID: transferID,
            sources: [
                GhosttyAttachmentTransferSource(
                    id: sourceID,
                    title: "Report",
                    payload: .securityScopedFile(file)
                ),
            ]
        )

        let paths = GhosttyRemoteAttachmentPathBuilder().paths(for: job)

        XCTAssertEqual(paths.count, 1)
        XCTAssertEqual(paths[0].sourceID, sourceID)
        XCTAssertEqual(paths[0].filename, "report.pdf")
        XCTAssertEqual(
            paths[0].remoteFinalPath,
            ".cache/remux/attachments/11111111-2222-3333-4444-555555555555/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/report.pdf"
        )
    }

    func testPreservesAbsoluteRemoteRoots() {
        let workspaceID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let transferID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let job = GhosttyAttachmentTransferJob(
            workspaceID: workspaceID,
            transferID: transferID,
            sources: [
                GhosttyAttachmentTransferSource(
                    title: "Log",
                    payload: .file(URL(fileURLWithPath: "/tmp/app.log"), filename: "app.log")
                ),
            ]
        )

        let paths = GhosttyRemoteAttachmentPathBuilder(
            remoteRoot: "/tmp/remux/uploads/",
            terminalRoot: "/tmp/remux/uploads/"
        ).paths(for: job)

        XCTAssertEqual(
            paths[0].remoteFinalPath,
            "/tmp/remux/uploads/11111111-2222-3333-4444-555555555555/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/app.log"
        )
        XCTAssertEqual(
            paths[0].terminalPath,
            "/tmp/remux/uploads/11111111-2222-3333-4444-555555555555/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/app.log"
        )
    }

    func testEmptyCustomRootsFallBackToDefaultRoots() {
        let workspaceID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let transferID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let job = GhosttyAttachmentTransferJob(
            workspaceID: workspaceID,
            transferID: transferID,
            sources: [
                GhosttyAttachmentTransferSource(
                    title: "Log",
                    payload: .file(URL(fileURLWithPath: "/tmp/app.log"), filename: "app.log")
                ),
            ]
        )

        let paths = GhosttyRemoteAttachmentPathBuilder(
            remoteRoot: "   ",
            terminalRoot: ""
        ).paths(for: job)

        XCTAssertEqual(
            paths[0].remoteFinalPath,
            ".cache/remux/attachments/11111111-2222-3333-4444-555555555555/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/app.log"
        )
        XCTAssertEqual(
            paths[0].terminalPath,
            "~/.cache/remux/attachments/11111111-2222-3333-4444-555555555555/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/app.log"
        )
    }

    func testTextAndLinksDoNotCreateUploadPaths() {
        let job = GhosttyAttachmentTransferJob(
            workspaceID: UUID(),
            transferID: UUID(),
            sources: [
                GhosttyAttachmentTransferSource(
                    title: "Text",
                    payload: .text("hello")
                ),
                GhosttyAttachmentTransferSource(
                    title: "Link",
                    payload: .link(URL(string: "https://example.com")!)
                ),
            ]
        )

        XCTAssertTrue(GhosttyRemoteAttachmentPathBuilder().paths(for: job).isEmpty)
    }

    func testBuildsRelativeDirectoryPrefixes() {
        XCTAssertEqual(
            GhosttyRemoteAttachmentPathBuilder.directoryPrefixes(
                for: ".cache/remux/attachments/workspace/transfer"
            ),
            [
                ".cache",
                ".cache/remux",
                ".cache/remux/attachments",
                ".cache/remux/attachments/workspace",
                ".cache/remux/attachments/workspace/transfer",
            ]
        )
    }

    func testBuildsAbsoluteDirectoryPrefixes() {
        XCTAssertEqual(
            GhosttyRemoteAttachmentPathBuilder.directoryPrefixes(
                for: "/tmp/remux/uploads/workspace"
            ),
            [
                "/tmp",
                "/tmp/remux",
                "/tmp/remux/uploads",
                "/tmp/remux/uploads/workspace",
            ]
        )
    }

    func testEmptyDirectoryPrefixesAreEmpty() {
        XCTAssertEqual(GhosttyRemoteAttachmentPathBuilder.directoryPrefixes(for: ""), [])
        XCTAssertEqual(GhosttyRemoteAttachmentPathBuilder.directoryPrefixes(for: "   "), [])
        XCTAssertEqual(GhosttyRemoteAttachmentPathBuilder.directoryPrefixes(for: "/"), [])
    }
}

final class RemuxSFTPReadableFileTests: XCTestCase {
    func testReadChunkPreservesOffsetLengthAndEOF() async throws {
        let source = Data("abcdefgh".utf8)
        let recorder = RemuxSFTPReadRequestRecorder()
        let file = RemuxSFTPReadableFile { offset, length in
            await recorder.record(offset: offset, length: length)
            guard offset < UInt64(source.count) else {
                return Data()
            }

            let start = Int(offset)
            let end = min(source.count, start + Int(length))
            return source.subdata(in: start..<end)
        }

        let middle = try await file.readChunk(from: 2, length: 3)
        let eof = try await file.readChunk(from: UInt64(source.count), length: 3)

        XCTAssertEqual(middle, Data("cde".utf8))
        XCTAssertEqual(eof, Data())
        let requests = await recorder.requests
        XCTAssertEqual(requests, [
            .init(offset: 2, length: 3),
            .init(offset: UInt64(source.count), length: 3),
        ])
    }

    func testReadChunkRejectsLengthsOutsideBoundBeforeDispatch() async {
        let recorder = RemuxSFTPReadRequestRecorder()
        let file = RemuxSFTPReadableFile { offset, length in
            await recorder.record(offset: offset, length: length)
            return Data()
        }

        for invalidLength in [0, -1, RemuxSFTPReadableFile.maximumChunkLength + 1] {
            do {
                _ = try await file.readChunk(from: 0, length: invalidLength)
                XCTFail("expected invalid read length \(invalidLength)")
            } catch let error as RemuxSFTPClientError {
                XCTAssertEqual(error, .invalidReadLength(invalidLength))
            } catch {
                XCTFail("unexpected error: \(error)")
            }
        }

        let requests = await recorder.requests
        XCTAssertEqual(requests, [])
    }

    func testReadChunkAcceptsMaximumLength() async throws {
        let recorder = RemuxSFTPReadRequestRecorder()
        let file = RemuxSFTPReadableFile { offset, length in
            await recorder.record(offset: offset, length: length)
            return Data()
        }

        _ = try await file.readChunk(
            from: 12,
            length: RemuxSFTPReadableFile.maximumChunkLength
        )

        let requests = await recorder.requests
        XCTAssertEqual(requests, [
            .init(
                offset: 12,
                length: UInt32(RemuxSFTPReadableFile.maximumChunkLength)
            ),
        ])
    }

    func testReadChunkRejectsOversizedResult() async {
        let file = RemuxSFTPReadableFile { _, _ in
            Data("too large".utf8)
        }

        do {
            _ = try await file.readChunk(from: 0, length: 3)
            XCTFail("expected oversized read result")
        } catch let error as RemuxSFTPClientError {
            XCTAssertEqual(
                error,
                .oversizedReadResult(requested: 3, actual: 9)
            )
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}

final class GhosttyAttachmentTransferSourceTests: XCTestCase {
    func testFileAttachmentCreatesTransferSourceWithFilename() {
        let url = URL(fileURLWithPath: "/tmp/remux/report.txt")
        let attachment = GhosttyPendingAttachment.file(url: url)

        let source = attachment.transferSource

        XCTAssertEqual(source?.attachmentID, attachment.id)
        XCTAssertEqual(source?.title, "report.txt")
        XCTAssertEqual(source?.payload, .file(url, filename: "report.txt"))
    }

    func testSecurityScopedFileAttachmentCreatesTransferSource() throws {
        let url = try makeTemporaryFile(named: "report.pdf", contents: "hello")
        let attachment = try GhosttyPendingAttachment.securityScopedFile(url: url)

        let source = attachment.transferSource

        XCTAssertEqual(source?.attachmentID, attachment.id)
        XCTAssertEqual(source?.title, "report.pdf")
        guard case .securityScopedFile(let file) = attachment.payload else {
            return XCTFail("Expected security-scoped payload")
        }
        XCTAssertEqual(source?.payload, .securityScopedFile(file))
    }

    func testLinkAttachmentCreatesTransferSource() {
        let url = URL(string: "https://example.com/remux")!
        let attachment = GhosttyPendingAttachment.pasteboardLink(url: url)

        let source = attachment.transferSource

        XCTAssertEqual(source?.attachmentID, attachment.id)
        XCTAssertEqual(source?.title, "Pasted link")
        XCTAssertEqual(source?.payload, .link(url))
    }

    func testTextAttachmentCreatesTransferSource() {
        let attachment = GhosttyPendingAttachment.pasteboardText("hello")

        let source = attachment.transferSource

        XCTAssertEqual(source?.attachmentID, attachment.id)
        XCTAssertEqual(source?.title, "Pasted text")
        XCTAssertEqual(source?.payload, .text("hello"))
    }

    func testEmptyTextAttachmentDoesNotCreateTransferSource() {
        let attachment = GhosttyPendingAttachment.pasteboardText(" \n\t ")

        XCTAssertNil(attachment.transferSource)
    }

    func testPreviewOnlyAttachmentDoesNotCreateTransferSource() {
        let attachment = GhosttyPendingAttachment.pasteboardImage(previewData: Data([0x01]))

        XCTAssertNil(attachment.transferSource)
    }

    private func makeTemporaryFile(named filename: String, contents: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("remux-attachment-source-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }

        let url = directory.appendingPathComponent(filename)
        guard let data = contents.data(using: .utf8) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url)
        return url
    }
}

final class GhosttyAttachmentTransferServiceTests: XCTestCase {
    func testTransferJobCountsUploadSources() {
        let job = GhosttyAttachmentTransferJob(
            workspaceID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            sources: [
                GhosttyAttachmentTransferSource(
                    title: "Photo",
                    payload: .file(URL(fileURLWithPath: "/tmp/photo.png"), filename: "photo.png")
                ),
                GhosttyAttachmentTransferSource(
                    title: "Note",
                    payload: .text("hello")
                ),
                GhosttyAttachmentTransferSource(
                    title: "Link",
                    payload: .link(URL(string: "https://remux.dev")!)
                ),
                GhosttyAttachmentTransferSource(
                    title: "Archive",
                    payload: .file(URL(fileURLWithPath: "/tmp/archive.zip"), filename: "archive.zip")
                ),
            ]
        )

        XCTAssertEqual(job.uploadSourceCount, 2)
    }

    func testServiceContractReturnsTransferResult() async throws {
        let sourceID = UUID(uuidString: "99999999-8888-7777-6666-555555555555")!
        let job = GhosttyAttachmentTransferJob(
            workspaceID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            transferID: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
            sources: [
                GhosttyAttachmentTransferSource(
                    id: sourceID,
                    title: "Note",
                    payload: .text("hello")
                ),
            ]
        )
        let expectedResult = GhosttyAttachmentTransferResult(
            transferID: job.transferID,
            items: [
                .text(sourceID: sourceID, text: "hello"),
            ]
        )
        let service = FakeGhosttyAttachmentTransferService(result: .success(expectedResult))

        let result = try await service.transfer(job, progress: { _ in })
        let jobs = await service.jobs

        XCTAssertEqual(result, expectedResult)
        XCTAssertEqual(jobs, [job])
    }

    func testServiceContractPropagatesTypedErrors() async {
        let job = GhosttyAttachmentTransferJob(
            workspaceID: UUID(),
            sources: []
        )
        let service = FakeGhosttyAttachmentTransferService(result: .failure(.noSources))

        do {
            _ = try await service.transfer(job, progress: { _ in })
            XCTFail("Expected transfer to throw")
        } catch let error as GhosttyAttachmentTransferError {
            XCTAssertEqual(error, .noSources)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

final class GhosttyAttachmentTerminalInsertionFormatterTests: XCTestCase {
    func testFormatsMixedTransferResultsInOrder() {
        let fileID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let textID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let linkID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let linkURL = URL(string: "https://remux.dev/docs")!
        let result = GhosttyAttachmentTransferResult(
            transferID: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
            items: [
                .remoteFile(
                    sourceID: fileID,
                    path: remotePath(sourceID: fileID, terminalPath: "~/.cache/remux/attachments/report.txt")
                ),
                .text(sourceID: textID, text: "note"),
                .link(sourceID: linkID, url: linkURL),
            ]
        )

        XCTAssertEqual(
            GhosttyAttachmentTerminalInsertionFormatter.insertionText(for: result),
            "~/.cache/remux/attachments/report.txt note https://remux.dev/docs"
        )
    }

    func testEscapesRemoteFilePathsWithWhitespaceAndQuotes() {
        let sourceID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let result = GhosttyAttachmentTransferResult(
            transferID: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
            items: [
                .remoteFile(
                    sourceID: sourceID,
                    path: remotePath(
                        sourceID: sourceID,
                        terminalPath: "~/.cache/remux/attachments/Bob's report.txt"
                    )
                ),
            ]
        )

        XCTAssertEqual(
            GhosttyAttachmentTerminalInsertionFormatter.insertionText(for: result),
            "~/'.cache/remux/attachments/Bob'\"'\"'s report.txt'"
        )
    }

    func testEscapesRemoteFilePathsWithShellMetacharacters() {
        let sourceID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let result = GhosttyAttachmentTransferResult(
            transferID: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
            items: [
                .remoteFile(
                    sourceID: sourceID,
                    path: remotePath(
                        sourceID: sourceID,
                        terminalPath: "~/.cache/remux/attachments/$(report);rm.txt"
                    )
                ),
            ]
        )

        XCTAssertEqual(
            GhosttyAttachmentTerminalInsertionFormatter.insertionText(for: result),
            "~/'.cache/remux/attachments/$(report);rm.txt'"
        )
    }

    func testPreservesPastedTextPayload() {
        let sourceID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let result = GhosttyAttachmentTransferResult(
            transferID: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
            items: [
                .text(sourceID: sourceID, text: "hello from preview\nsecond line"),
            ]
        )

        XCTAssertEqual(
            GhosttyAttachmentTerminalInsertionFormatter.insertionText(for: result),
            "hello from preview\nsecond line"
        )
    }

    private func remotePath(
        sourceID: GhosttyAttachmentTransferSource.ID,
        terminalPath: String
    ) -> GhosttyRemoteAttachmentPath {
        GhosttyRemoteAttachmentPath(
            sourceID: sourceID,
            filename: URL(fileURLWithPath: terminalPath).lastPathComponent,
            remoteDirectory: ".cache/remux/attachments/workspace/transfer",
            remoteTemporaryPath: ".cache/remux/attachments/workspace/transfer/.attachment.part",
            remoteFinalPath: ".cache/remux/attachments/workspace/transfer/attachment",
            terminalPath: terminalPath
        )
    }
}

final class GhosttyAttachmentTransferJobBuilderTests: XCTestCase {
    func testBuildsJobFromTransferableAttachments() throws {
        let workspaceID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let textAttachment = GhosttyPendingAttachment.pasteboardText("hello")
        let linkURL = URL(string: "https://example.com")!
        let linkAttachment = GhosttyPendingAttachment.pasteboardLink(url: linkURL)

        let job = try GhosttyAttachmentTransferJobBuilder.job(
            workspaceID: workspaceID,
            attachments: [
                GhosttyPendingAttachment.pasteboardImage(previewData: Data([0x01])),
                textAttachment,
                linkAttachment,
            ]
        )

        XCTAssertEqual(job.workspaceID, workspaceID)
        XCTAssertEqual(job.sources.count, 2)
        XCTAssertEqual(job.sources[0].attachmentID, textAttachment.id)
        XCTAssertEqual(job.sources[0].payload, .text("hello"))
        XCTAssertEqual(job.sources[1].attachmentID, linkAttachment.id)
        XCTAssertEqual(job.sources[1].payload, .link(linkURL))
    }

    func testThrowsWhenNoTransferableAttachmentsExist() {
        XCTAssertThrowsError(
            try GhosttyAttachmentTransferJobBuilder.job(
                workspaceID: UUID(),
                attachments: [
                    GhosttyPendingAttachment.pasteboardImage(previewData: Data([0x01])),
                ]
            )
        ) { error in
            XCTAssertEqual(error as? GhosttyAttachmentTransferError, .noSources)
        }
    }
}

final class GhosttyAttachmentSFTPTransferServiceTests: XCTestCase {
    func testTransfersMixedSourcesInOrder() async throws {
        let workspaceID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let transferID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let textID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let fileID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let linkID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let localURL = try makeTemporaryFile(named: "report.txt", contents: "hello")
        let linkURL = URL(string: "https://example.com/remux")!
        let job = GhosttyAttachmentTransferJob(
            workspaceID: workspaceID,
            transferID: transferID,
            sources: [
                GhosttyAttachmentTransferSource(
                    id: textID,
                    title: "Note",
                    payload: .text("hello")
                ),
                GhosttyAttachmentTransferSource(
                    id: fileID,
                    title: "Report",
                    payload: .file(localURL, filename: "report.txt")
                ),
                GhosttyAttachmentTransferSource(
                    id: linkID,
                    title: "Link",
                    payload: .link(linkURL)
                ),
            ]
        )
        let client = FakeGhosttyAttachmentSFTPClient()
        let service = GhosttyAttachmentSFTPTransferService(client: client)

        let result = try await service.transfer(job, progress: { _ in })
        let events = await client.events

        let remoteDirectory = ".cache/remux/attachments/11111111-2222-3333-4444-555555555555/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        let temporaryPath = "\(remoteDirectory)/.report.txt.part"
        let finalPath = "\(remoteDirectory)/report.txt"
        XCTAssertEqual(events, [
            .ensureDirectory(".cache"),
            .ensureDirectory(".cache/remux"),
            .ensureDirectory(".cache/remux/attachments"),
            .ensureDirectory(".cache/remux/attachments/11111111-2222-3333-4444-555555555555"),
            .ensureDirectory(remoteDirectory),
            .upload(localPath: localURL.path, remotePath: temporaryPath),
            .rename(temporaryPath: temporaryPath, finalPath: finalPath),
            .realPath(finalPath),
        ])
        XCTAssertEqual(result, GhosttyAttachmentTransferResult(
            transferID: transferID,
            items: [
                .text(sourceID: textID, text: "hello"),
                .remoteFile(
                    sourceID: fileID,
                    path: GhosttyRemoteAttachmentPath(
                        sourceID: fileID,
                        filename: "report.txt",
                        remoteDirectory: remoteDirectory,
                        remoteTemporaryPath: temporaryPath,
                        remoteFinalPath: finalPath,
                        terminalPath: "/Users/remux/.cache/remux/attachments/11111111-2222-3333-4444-555555555555/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/report.txt"
                    )
                ),
                .link(sourceID: linkID, url: linkURL),
            ]
        ))
    }

    func testTransfersSecurityScopedFileSource() async throws {
        let workspaceID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let transferID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let sourceID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let localURL = try makeTemporaryFile(named: "report.pdf", contents: "hello")
        let file = try GhosttySecurityScopedAttachmentFile.make(url: localURL)
        let job = GhosttyAttachmentTransferJob(
            workspaceID: workspaceID,
            transferID: transferID,
            sources: [
                GhosttyAttachmentTransferSource(
                    id: sourceID,
                    title: "Report",
                    payload: .securityScopedFile(file)
                ),
            ]
        )
        let client = FakeGhosttyAttachmentSFTPClient()
        let service = GhosttyAttachmentSFTPTransferService(client: client)

        let result = try await service.transfer(job, progress: { _ in })
        let events = await client.events

        let remoteDirectory = ".cache/remux/attachments/11111111-2222-3333-4444-555555555555/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        let temporaryPath = "\(remoteDirectory)/.report.pdf.part"
        let finalPath = "\(remoteDirectory)/report.pdf"
        XCTAssertEqual(events, [
            .ensureDirectory(".cache"),
            .ensureDirectory(".cache/remux"),
            .ensureDirectory(".cache/remux/attachments"),
            .ensureDirectory(".cache/remux/attachments/11111111-2222-3333-4444-555555555555"),
            .ensureDirectory(remoteDirectory),
            .upload(localPath: localURL.path, remotePath: temporaryPath),
            .rename(temporaryPath: temporaryPath, finalPath: finalPath),
            .realPath(finalPath),
        ])
        XCTAssertEqual(result.items, [
            .remoteFile(
                sourceID: sourceID,
                path: GhosttyRemoteAttachmentPath(
                    sourceID: sourceID,
                    filename: "report.pdf",
                    remoteDirectory: remoteDirectory,
                    remoteTemporaryPath: temporaryPath,
                    remoteFinalPath: finalPath,
                    terminalPath: "/Users/remux/.cache/remux/attachments/11111111-2222-3333-4444-555555555555/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/report.pdf"
                )
            ),
        ])
    }

    func testReportsPerFileProgressForSequentialUploads() async throws {
        let workspaceID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let transferID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let firstURL = try makeTemporaryFile(named: "first.txt", contents: "abcd")
        let secondURL = try makeTemporaryFile(named: "second.txt", contents: "abcdefgh")
        let job = GhosttyAttachmentTransferJob(
            workspaceID: workspaceID,
            transferID: transferID,
            sources: [
                GhosttyAttachmentTransferSource(
                    title: "First",
                    payload: .file(firstURL, filename: "first.txt")
                ),
                GhosttyAttachmentTransferSource(
                    title: "Second",
                    payload: .file(secondURL, filename: "second.txt")
                ),
            ]
        )
        let client = FakeGhosttyAttachmentSFTPClient()
        let progressRecorder = GhosttyAttachmentProgressRecorder()
        let service = GhosttyAttachmentSFTPTransferService(client: client)

        _ = try await service.transfer(job) { progress in
            await progressRecorder.append(progress)
        }

        let progresses = await progressRecorder.progresses
        XCTAssertEqual(progresses, [
            GhosttyAttachmentTransferProgress(
                completedUploadCount: 0,
                totalUploadCount: 2,
                currentUploadIndex: 1,
                currentUploadedBytes: 0,
                currentTotalBytes: 4
            ),
            GhosttyAttachmentTransferProgress(
                completedUploadCount: 0,
                totalUploadCount: 2,
                currentUploadIndex: 1,
                currentUploadedBytes: 2,
                currentTotalBytes: 4
            ),
            GhosttyAttachmentTransferProgress(
                completedUploadCount: 0,
                totalUploadCount: 2,
                currentUploadIndex: 1,
                currentUploadedBytes: 4,
                currentTotalBytes: 4
            ),
            GhosttyAttachmentTransferProgress(
                completedUploadCount: 1,
                totalUploadCount: 2,
                currentUploadIndex: 2,
                currentUploadedBytes: 0,
                currentTotalBytes: 8
            ),
            GhosttyAttachmentTransferProgress(
                completedUploadCount: 1,
                totalUploadCount: 2,
                currentUploadIndex: 2,
                currentUploadedBytes: 4,
                currentTotalBytes: 8
            ),
            GhosttyAttachmentTransferProgress(
                completedUploadCount: 1,
                totalUploadCount: 2,
                currentUploadIndex: 2,
                currentUploadedBytes: 8,
                currentTotalBytes: 8
            ),
        ])
    }

    func testRejectsUnresolvableSecurityScopedFileBeforeRemoteOperations() async {
        let file = GhosttySecurityScopedAttachmentFile(
            bookmarkData: Data([0xde, 0xad, 0xbe, 0xef]),
            originalURL: URL(fileURLWithPath: "/tmp/missing.pdf"),
            filename: "missing.pdf"
        )
        let job = GhosttyAttachmentTransferJob(
            workspaceID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            transferID: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
            sources: [
                GhosttyAttachmentTransferSource(
                    title: "Missing",
                    payload: .securityScopedFile(file)
                ),
            ]
        )
        let client = FakeGhosttyAttachmentSFTPClient()
        let service = GhosttyAttachmentSFTPTransferService(client: client)

        do {
            _ = try await service.transfer(job, progress: { _ in })
            XCTFail("Expected transfer to throw")
        } catch let error as GhosttyAttachmentTransferError {
            XCTAssertEqual(error, .securityScopedSourceUnavailable("missing.pdf"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let events = await client.events
        XCTAssertEqual(events, [])
    }

    func testProviderBackedServiceRejectsEmptyJobsBeforeLeasingClient() async {
        let job = GhosttyAttachmentTransferJob(
            workspaceID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            transferID: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
            sources: []
        )
        let client = FakeGhosttyAttachmentSFTPClient()
        let provider = FakeGhosttyAttachmentSFTPClientProvider(client: client)
        let service = GhosttyAttachmentSFTPClientProviderTransferService(provider: provider)

        do {
            _ = try await service.transfer(job, progress: { _ in })
            XCTFail("Expected transfer to throw")
        } catch let error as GhosttyAttachmentTransferError {
            XCTAssertEqual(error, .noSources)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let leaseCount = await provider.leaseCount
        let events = await client.events
        XCTAssertEqual(leaseCount, 0)
        XCTAssertEqual(events, [])
    }

    func testProviderBackedServicePassesThroughTextAndLinksWithoutLeasingClient() async throws {
        let textID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let linkID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let linkURL = URL(string: "https://remux.dev/docs")!
        let transferID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let job = GhosttyAttachmentTransferJob(
            workspaceID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            transferID: transferID,
            sources: [
                GhosttyAttachmentTransferSource(
                    id: textID,
                    title: "Text",
                    payload: .text("hello")
                ),
                GhosttyAttachmentTransferSource(
                    id: linkID,
                    title: "Link",
                    payload: .link(linkURL)
                ),
            ]
        )
        let client = FakeGhosttyAttachmentSFTPClient()
        let provider = FakeGhosttyAttachmentSFTPClientProvider(client: client)
        let service = GhosttyAttachmentSFTPClientProviderTransferService(provider: provider)

        let result = try await service.transfer(job, progress: { _ in })
        let leaseCount = await provider.leaseCount
        let events = await client.events

        XCTAssertEqual(leaseCount, 0)
        XCTAssertEqual(events, [])
        XCTAssertEqual(result, GhosttyAttachmentTransferResult(
            transferID: transferID,
            items: [
                .text(sourceID: textID, text: "hello"),
                .link(sourceID: linkID, url: linkURL),
            ]
        ))
    }

    func testProviderBackedServiceUsesOneClientLeaseForBatch() async throws {
        let sourceID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let localURL = try makeTemporaryFile(named: "report.txt", contents: "hello")
        let job = GhosttyAttachmentTransferJob(
            workspaceID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            transferID: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
            sources: [
                GhosttyAttachmentTransferSource(
                    id: sourceID,
                    title: "Report",
                    payload: .file(localURL, filename: "report.txt")
                ),
            ]
        )
        let client = FakeGhosttyAttachmentSFTPClient()
        let provider = FakeGhosttyAttachmentSFTPClientProvider(client: client)
        let service = GhosttyAttachmentSFTPClientProviderTransferService(provider: provider)

        let result = try await service.transfer(job, progress: { _ in })
        let leaseCount = await provider.leaseCount
        let events = await client.events

        XCTAssertEqual(leaseCount, 1)
        XCTAssertEqual(result.items.count, 1)
        XCTAssertEqual(Array(events.suffix(3)), [
            .upload(
                localPath: localURL.path,
                remotePath: ".cache/remux/attachments/11111111-2222-3333-4444-555555555555/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/.report.txt.part"
            ),
            .rename(
                temporaryPath: ".cache/remux/attachments/11111111-2222-3333-4444-555555555555/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/.report.txt.part",
                finalPath: ".cache/remux/attachments/11111111-2222-3333-4444-555555555555/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/report.txt"
            ),
            .realPath(".cache/remux/attachments/11111111-2222-3333-4444-555555555555/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/report.txt"),
        ])
    }

    func testShortLivedProviderClosesLeaseAfterSuccessfulOperation() async throws {
        let client = FakeGhosttyAttachmentSFTPClient()
        let leaseState = FakeGhosttyAttachmentSFTPLeaseState()
        let provider = RemuxShortLivedSFTPClientProvider(
            openLease: {
                RemuxSFTPClientLease(
                    client: client,
                    close: { try await leaseState.close() }
                )
            }
        )

        let result = try await provider.withClient { client in
            try await client.ensureDirectoryExists(atPath: ".cache")
            return "ok"
        }
        let closeCount = await leaseState.closeCount
        let events = await client.events

        XCTAssertEqual(result, "ok")
        XCTAssertEqual(closeCount, 1)
        XCTAssertEqual(events, [.ensureDirectory(".cache")])
    }

    func testShortLivedProviderClosesLeaseAfterOperationFailure() async {
        let client = FakeGhosttyAttachmentSFTPClient()
        let leaseState = FakeGhosttyAttachmentSFTPLeaseState()
        let provider = RemuxShortLivedSFTPClientProvider(
            openLease: {
                RemuxSFTPClientLease(
                    client: client,
                    close: { try await leaseState.close() }
                )
            }
        )

        do {
            _ = try await provider.withClient { (_: FakeGhosttyAttachmentSFTPClient) in
                throw FakeGhosttyAttachmentSFTPLeaseFailure.operation
            } as Void
            XCTFail("Expected operation to throw")
        } catch let error as FakeGhosttyAttachmentSFTPLeaseFailure {
            XCTAssertEqual(error, .operation)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let closeCount = await leaseState.closeCount
        XCTAssertEqual(closeCount, 1)
    }

    func testShortLivedProviderDoesNotFailSuccessfulOperationWhenCloseFails() async throws {
        let client = FakeGhosttyAttachmentSFTPClient()
        let leaseState = FakeGhosttyAttachmentSFTPLeaseState(closeFailure: .close)
        let provider = RemuxShortLivedSFTPClientProvider(
            openLease: {
                RemuxSFTPClientLease(
                    client: client,
                    close: { try await leaseState.close() }
                )
            },
            closeFailureHandler: { _ in }
        )

        let result = try await provider.withClient { (_: FakeGhosttyAttachmentSFTPClient) in
            "ok"
        }
        let closeCount = await leaseState.closeCount

        XCTAssertEqual(result, "ok")
        XCTAssertEqual(closeCount, 1)
    }

    func testRejectsMissingLocalFilesBeforeRemoteOperations() async {
        let localURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).txt")
        let job = GhosttyAttachmentTransferJob(
            workspaceID: UUID(),
            sources: [
                GhosttyAttachmentTransferSource(
                    title: "Missing",
                    payload: .file(localURL, filename: "missing.txt")
                ),
            ]
        )
        let client = FakeGhosttyAttachmentSFTPClient()
        let service = GhosttyAttachmentSFTPTransferService(client: client)

        do {
            _ = try await service.transfer(job, progress: { _ in })
            XCTFail("Expected transfer to throw")
        } catch let error as GhosttyAttachmentTransferError {
            XCTAssertEqual(error, .localSourceUnavailable(localURL))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let events = await client.events
        XCTAssertEqual(events, [])
    }

    func testPreflightsAllLocalFilesBeforeRemoteOperations() async throws {
        let validURL = try makeTemporaryFile(named: "valid.txt", contents: "hello")
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).txt")
        let job = GhosttyAttachmentTransferJob(
            workspaceID: UUID(),
            sources: [
                GhosttyAttachmentTransferSource(
                    title: "Valid",
                    payload: .file(validURL, filename: "valid.txt")
                ),
                GhosttyAttachmentTransferSource(
                    title: "Missing",
                    payload: .file(missingURL, filename: "missing.txt")
                ),
            ]
        )
        let client = FakeGhosttyAttachmentSFTPClient()
        let service = GhosttyAttachmentSFTPTransferService(client: client)

        do {
            _ = try await service.transfer(job, progress: { _ in })
            XCTFail("Expected transfer to throw")
        } catch let error as GhosttyAttachmentTransferError {
            XCTAssertEqual(error, .localSourceUnavailable(missingURL))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let events = await client.events
        XCTAssertEqual(events, [])
    }

    func testFallsBackToResolvedUploadPathWhenRemoteFinalPathResolutionFails() async throws {
        let localURL = try makeTemporaryFile(named: "report.txt", contents: "hello")
        let workspaceID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let transferID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let sourceID = UUID(uuidString: "bbbbbbbb-cccc-dddd-eeee-ffffffffffff")!
        let job = GhosttyAttachmentTransferJob(
            workspaceID: workspaceID,
            transferID: transferID,
            sources: [
                GhosttyAttachmentTransferSource(
                    id: sourceID,
                    title: "Report",
                    payload: .file(localURL, filename: "report.txt")
                ),
            ]
        )
        let client = FakeGhosttyAttachmentSFTPClient(failure: .realPath)
        let service = GhosttyAttachmentSFTPTransferService(client: client)

        let result = try await service.transfer(job, progress: { _ in })

        let remoteDirectory = ".cache/remux/attachments/11111111-2222-3333-4444-555555555555/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        let temporaryPath = "\(remoteDirectory)/.report.txt.part"
        let finalPath = "\(remoteDirectory)/report.txt"
        XCTAssertEqual(result, GhosttyAttachmentTransferResult(
            transferID: transferID,
            items: [
                .remoteFile(
                    sourceID: sourceID,
                    path: GhosttyRemoteAttachmentPath(
                        sourceID: sourceID,
                        filename: "report.txt",
                        remoteDirectory: remoteDirectory,
                        remoteTemporaryPath: temporaryPath,
                        remoteFinalPath: finalPath,
                        terminalPath: "~/.cache/remux/attachments/11111111-2222-3333-4444-555555555555/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/report.txt"
                    )
                ),
            ]
        ))

        let events = await client.events
        XCTAssertEqual(events, [
            .ensureDirectory(".cache"),
            .ensureDirectory(".cache/remux"),
            .ensureDirectory(".cache/remux/attachments"),
            .ensureDirectory(".cache/remux/attachments/11111111-2222-3333-4444-555555555555"),
            .ensureDirectory(".cache/remux/attachments/11111111-2222-3333-4444-555555555555/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"),
            .upload(
                localPath: localURL.path,
                remotePath: temporaryPath
            ),
            .rename(
                temporaryPath: temporaryPath,
                finalPath: finalPath
            ),
            .realPath(finalPath),
        ])
    }

    func testMapsCancellationBeforeRemoteOperations() async throws {
        let localURL = try makeTemporaryFile(named: "cancelled.txt", contents: "hello")
        let job = GhosttyAttachmentTransferJob(
            workspaceID: UUID(),
            sources: [
                GhosttyAttachmentTransferSource(
                    title: "Cancelled",
                    payload: .file(localURL, filename: "cancelled.txt")
                ),
            ]
        )
        let client = FakeGhosttyAttachmentSFTPClient()
        let service = GhosttyAttachmentSFTPTransferService(client: client)
        let gate = AsyncGate()

        let task = Task {
            await gate.wait()
            return try await service.transfer(job, progress: { _ in })
        }
        task.cancel()
        await gate.open()

        do {
            _ = try await task.value
            XCTFail("Expected transfer to throw")
        } catch let error as GhosttyAttachmentTransferError {
            XCTAssertEqual(error, .cancelled)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let events = await client.events
        XCTAssertEqual(events, [])
    }

    func testCleansTemporaryFileWhenUploadFails() async throws {
        let localURL = try makeTemporaryFile(named: "upload-failure.txt", contents: "hello")
        let job = GhosttyAttachmentTransferJob(
            workspaceID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            transferID: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
            sources: [
                GhosttyAttachmentTransferSource(
                    title: "Upload failure",
                    payload: .file(localURL, filename: "upload-failure.txt")
                ),
            ]
        )
        let client = FakeGhosttyAttachmentSFTPClient(failure: .upload)
        let service = GhosttyAttachmentSFTPTransferService(client: client)

        do {
            _ = try await service.transfer(job, progress: { _ in })
            XCTFail("Expected transfer to throw")
        } catch let error as GhosttyAttachmentTransferError {
            XCTAssertEqual(error, .uploadFailed(
                remotePath: ".cache/remux/attachments/11111111-2222-3333-4444-555555555555/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/.upload-failure.txt.part"
            ))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let events = await client.events
        XCTAssertEqual(events.last, .remove(
            ".cache/remux/attachments/11111111-2222-3333-4444-555555555555/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/.upload-failure.txt.part"
        ))
    }

    func testPreservesUploadFailureWhenTemporaryCleanupFails() async throws {
        let localURL = try makeTemporaryFile(named: "cleanup-failure.txt", contents: "hello")
        let job = GhosttyAttachmentTransferJob(
            workspaceID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            transferID: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
            sources: [
                GhosttyAttachmentTransferSource(
                    title: "Cleanup failure",
                    payload: .file(localURL, filename: "cleanup-failure.txt")
                ),
            ]
        )
        let client = FakeGhosttyAttachmentSFTPClient(failure: .uploadAndRemove)
        let service = GhosttyAttachmentSFTPTransferService(client: client)

        do {
            _ = try await service.transfer(job, progress: { _ in })
            XCTFail("Expected transfer to throw")
        } catch let error as GhosttyAttachmentTransferError {
            XCTAssertEqual(error, .uploadFailed(
                remotePath: ".cache/remux/attachments/11111111-2222-3333-4444-555555555555/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/.cleanup-failure.txt.part"
            ))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let events = await client.events
        XCTAssertEqual(events.last, .remove(
            ".cache/remux/attachments/11111111-2222-3333-4444-555555555555/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/.cleanup-failure.txt.part"
        ))
    }

    func testStopsTransferWithoutCleanupWhenRemoteOperationTimesOut() async throws {
        let localURL = try makeTemporaryFile(named: "timeout.txt", contents: "hello")
        let job = GhosttyAttachmentTransferJob(
            workspaceID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            transferID: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
            sources: [
                GhosttyAttachmentTransferSource(
                    title: "Timeout",
                    payload: .file(localURL, filename: "timeout.txt")
                ),
            ]
        )
        let client = FakeGhosttyAttachmentSFTPClient(failure: .uploadTimeout)
        let service = GhosttyAttachmentSFTPTransferService(client: client)

        do {
            _ = try await service.transfer(job, progress: { _ in })
            XCTFail("Expected transfer to throw")
        } catch let error as GhosttyAttachmentTransferError {
            XCTAssertEqual(error, .remoteOperationTimedOut)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let events = await client.events
        XCTAssertEqual(events.last, .upload(
            localPath: localURL.path,
            remotePath: ".cache/remux/attachments/11111111-2222-3333-4444-555555555555/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/.timeout.txt.part"
        ))
        XCTAssertFalse(events.contains {
            if case .remove = $0 {
                return true
            }
            return false
        })
    }

    func testCleansTemporaryFileWhenRenameFails() async throws {
        let localURL = try makeTemporaryFile(named: "rename-failure.txt", contents: "hello")
        let job = GhosttyAttachmentTransferJob(
            workspaceID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            transferID: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
            sources: [
                GhosttyAttachmentTransferSource(
                    title: "Rename failure",
                    payload: .file(localURL, filename: "rename-failure.txt")
                ),
            ]
        )
        let client = FakeGhosttyAttachmentSFTPClient(failure: .rename)
        let service = GhosttyAttachmentSFTPTransferService(client: client)

        do {
            _ = try await service.transfer(job, progress: { _ in })
            XCTFail("Expected transfer to throw")
        } catch let error as GhosttyAttachmentTransferError {
            XCTAssertEqual(error, .remoteRenameFailed(
                from: ".cache/remux/attachments/11111111-2222-3333-4444-555555555555/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/.rename-failure.txt.part",
                to: ".cache/remux/attachments/11111111-2222-3333-4444-555555555555/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/rename-failure.txt"
            ))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let events = await client.events
        XCTAssertEqual(Array(events.suffix(3)), [
            .upload(
                localPath: localURL.path,
                remotePath: ".cache/remux/attachments/11111111-2222-3333-4444-555555555555/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/.rename-failure.txt.part"
            ),
            .rename(
                temporaryPath: ".cache/remux/attachments/11111111-2222-3333-4444-555555555555/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/.rename-failure.txt.part",
                finalPath: ".cache/remux/attachments/11111111-2222-3333-4444-555555555555/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/rename-failure.txt"
            ),
            .remove(".cache/remux/attachments/11111111-2222-3333-4444-555555555555/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/.rename-failure.txt.part"),
        ])
    }

    private func makeTemporaryFile(named filename: String, contents: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("remux-attachment-transfer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }

        let url = directory.appendingPathComponent(filename)
        guard let data = contents.data(using: .utf8) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url)
        return url
    }
}

private actor AsyncGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        if isOpen {
            return
        }

        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

private actor RemuxSFTPReadRequestRecorder {
    struct Request: Equatable, Sendable {
        let offset: UInt64
        let length: UInt32
    }

    private(set) var requests: [Request] = []

    func record(offset: UInt64, length: UInt32) {
        requests.append(Request(offset: offset, length: length))
    }
}

private actor GhosttyAttachmentProgressRecorder {
    private(set) var progresses: [GhosttyAttachmentTransferProgress] = []

    func append(_ progress: GhosttyAttachmentTransferProgress) {
        progresses.append(progress)
    }
}

private actor FakeGhosttyAttachmentTransferService: GhosttyAttachmentTransferService {
    private let result: Result<GhosttyAttachmentTransferResult, GhosttyAttachmentTransferError>
    private(set) var jobs: [GhosttyAttachmentTransferJob] = []

    init(result: Result<GhosttyAttachmentTransferResult, GhosttyAttachmentTransferError>) {
        self.result = result
    }

    func transfer(
        _ job: GhosttyAttachmentTransferJob,
        progress: @escaping GhosttyAttachmentTransferProgressHandler
    ) async throws -> GhosttyAttachmentTransferResult {
        jobs.append(job)
        return try result.get()
    }
}

private enum FakeGhosttyAttachmentSFTPFailure: Error, Equatable, Sendable {
    case realPath
    case ensureDirectory
    case upload
    case rename
    case remove
    case uploadAndRemove
    case uploadTimeout
}

private enum FakeGhosttyAttachmentSFTPLeaseFailure: Error, Equatable, Sendable {
    case operation
    case close
}

private actor FakeGhosttyAttachmentSFTPLeaseState {
    private let closeFailure: FakeGhosttyAttachmentSFTPLeaseFailure?
    private(set) var closeCount = 0

    init(closeFailure: FakeGhosttyAttachmentSFTPLeaseFailure? = nil) {
        self.closeFailure = closeFailure
    }

    func close() throws {
        closeCount += 1
        if let closeFailure {
            throw closeFailure
        }
    }
}

private actor FakeGhosttyAttachmentSFTPClient: RemuxSFTPUploadClient {
    enum Event: Equatable, Sendable {
        case realPath(String)
        case ensureDirectory(String)
        case upload(localPath: String, remotePath: String)
        case rename(temporaryPath: String, finalPath: String)
        case remove(String)
    }

    private let failure: FakeGhosttyAttachmentSFTPFailure?
    private(set) var events: [Event] = []

    init(failure: FakeGhosttyAttachmentSFTPFailure? = nil) {
        self.failure = failure
    }

    func realPath(atPath path: String) async throws -> String {
        events.append(.realPath(path))
        if failure == .realPath {
            throw FakeGhosttyAttachmentSFTPFailure.realPath
        }
        if path.hasPrefix("/") {
            return path
        }
        return "/Users/remux/\(path)"
    }

    func ensureDirectoryExists(atPath path: String) async throws {
        events.append(.ensureDirectory(path))
        if failure == .ensureDirectory {
            throw FakeGhosttyAttachmentSFTPFailure.ensureDirectory
        }
    }

    func uploadFile(
        from localURL: URL,
        to remotePath: String,
        progress: @escaping RemuxSFTPFileUploadProgressHandler
    ) async throws {
        events.append(.upload(localPath: localURL.path, remotePath: remotePath))
        if failure == .uploadTimeout {
            throw RemuxSFTPClientError.operationTimedOut
        }
        if failure == .upload || failure == .uploadAndRemove {
            throw FakeGhosttyAttachmentSFTPFailure.upload
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: localURL.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        if size > 1 {
            await progress(size / 2)
        }
        await progress(size)
    }

    func renameFile(from temporaryPath: String, to finalPath: String) async throws {
        events.append(.rename(temporaryPath: temporaryPath, finalPath: finalPath))
        if failure == .rename {
            throw FakeGhosttyAttachmentSFTPFailure.rename
        }
    }

    func removeFileIfExists(atPath path: String) async throws {
        events.append(.remove(path))
        if failure == .remove || failure == .uploadAndRemove {
            throw FakeGhosttyAttachmentSFTPFailure.remove
        }
    }
}

private actor FakeGhosttyAttachmentSFTPClientProvider: RemuxSFTPClientProvider {
    private let client: FakeGhosttyAttachmentSFTPClient
    private(set) var leaseCount = 0

    init(client: FakeGhosttyAttachmentSFTPClient) {
        self.client = client
    }

    func withClient<ReturnValue: Sendable>(
        _ operation: @Sendable (FakeGhosttyAttachmentSFTPClient) async throws -> ReturnValue
    ) async throws -> ReturnValue {
        leaseCount += 1
        return try await operation(client)
    }
}
