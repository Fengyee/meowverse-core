import Foundation
import Testing
@testable import MeowverseCore

/// JOURNEY-NEW-1: a full disk can be told apart from other failed saves. The store keeps a failed
/// write only as "<op>:<domain>:<code>" (`ioError`); injected faults aren't wrapped that way, so
/// the codes are written out here as it writes them.
@Suite struct OutOfSpaceTests {
    @Test(arguments: ["addPhoto:NSCocoaErrorDomain:640", "persist:NSCocoaErrorDomain:640", "addPhoto:NSPOSIXErrorDomain:28"])
    func aFullDiskIsOutOfSpace(code: String) {
        #expect(StoreError.io(code).isOutOfSpace)
    }

    @Test(arguments: ["addPhoto:NSCocoaErrorDomain:512", "addPhoto:NSPOSIXErrorDomain:5", "addPhoto:NSPOSIXErrorDomain:128"])
    func anotherFailureIsNot(code: String) {
        #expect(!StoreError.io(code).isOutOfSpace)
    }
}
