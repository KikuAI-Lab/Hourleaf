import Darwin
import Foundation

enum QuickSurfaceStateStoreLeaseMode: Sendable {
    case shared
    case exclusive
}

struct QuickSurfaceStateStoreFileIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64

    init(_ metadata: stat) {
        device = UInt64(metadata.st_dev)
        inode = UInt64(metadata.st_ino)
    }
}

/// Owns one descriptor and the corresponding advisory lock. The descriptor is
/// deliberately retained for the lifetime of a restore boundary. Ordinary
/// operations acquire and release a short-lived instance synchronously.
final class QuickSurfaceStateStoreLease: @unchecked Sendable {
    let mode: QuickSurfaceStateStoreLeaseMode
    let rootURL: URL
    let lockURL: URL
    let rootIdentity: QuickSurfaceStateStoreFileIdentity
    let lockIdentity: QuickSurfaceStateStoreFileIdentity

    private let stateLock = NSLock()
    private var descriptor: Int32?

    private init(
        mode: QuickSurfaceStateStoreLeaseMode,
        rootURL: URL,
        lockURL: URL,
        rootIdentity: QuickSurfaceStateStoreFileIdentity,
        lockIdentity: QuickSurfaceStateStoreFileIdentity,
        descriptor: Int32
    ) {
        self.mode = mode
        self.rootURL = rootURL
        self.lockURL = lockURL
        self.rootIdentity = rootIdentity
        self.lockIdentity = lockIdentity
        self.descriptor = descriptor
    }

    deinit {
        releaseIgnoringErrors()
    }

    static func acquire(
        mode: QuickSurfaceStateStoreLeaseMode,
        rootURL: URL,
        lockURL: URL
    ) throws -> QuickSurfaceStateStoreLease {
        let root = rootURL.standardizedFileURL
        let lock = lockURL.standardizedFileURL
        let rootMetadata = try validateRootAndLockParent(root: root, lock: lock)

        let descriptor = try openLockFile(at: lock)
        do {
            let initialLockMetadata = try validateDescriptorAndPath(
                descriptor: descriptor,
                root: root,
                lock: lock
            )

            let operation = mode == .shared ? LOCK_SH : LOCK_EX
            guard flock(descriptor, operation | LOCK_NB) == 0 else {
                let code = errno
                if code == EWOULDBLOCK {
                    throw QuickSurfaceStateStoreError.accessBusy
                }
                throw QuickSurfaceStateStoreError.leaseUnavailable
            }

            // Re-check both descriptor and path after locking. This closes
            // the create/replacement window between open and flock.
            let lockedMetadata = try validateDescriptorAndPath(
                descriptor: descriptor,
                root: root,
                lock: lock
            )
            guard lockedMetadata == initialLockMetadata else {
                throw QuickSurfaceStateStoreError.leaseIdentityMismatch
            }
            let lockedRootMetadata = try lstat(at: root)
            guard QuickSurfaceStateStoreFileIdentity(lockedRootMetadata)
                == QuickSurfaceStateStoreFileIdentity(rootMetadata)
            else {
                throw QuickSurfaceStateStoreError.leaseIdentityMismatch
            }
            return QuickSurfaceStateStoreLease(
                mode: mode,
                rootURL: root,
                lockURL: lock,
                rootIdentity: QuickSurfaceStateStoreFileIdentity(rootMetadata),
                lockIdentity: lockedMetadata,
                descriptor: descriptor
            )
        } catch {
            _ = flock(descriptor, LOCK_UN)
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    /// Validates that this lease is still live and that its path/inode have not
    /// been replaced. A replacement is fail-closed; it can never silently
    /// retarget a leased view to another lock file.
    func validate(root expectedRoot: URL, lock expectedLock: URL) throws {
        let root = expectedRoot.standardizedFileURL
        let lock = expectedLock.standardizedFileURL
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let descriptor else {
            throw QuickSurfaceStateStoreError.leaseReleased
        }
        guard mode == .exclusive else {
            throw QuickSurfaceStateStoreError.leaseUnavailable
        }
        guard root == rootURL.standardizedFileURL else {
            throw QuickSurfaceStateStoreError.leaseRootMismatch
        }
        guard lock == lockURL.standardizedFileURL else {
            throw QuickSurfaceStateStoreError.leaseRootMismatch
        }

        try validateLive(root: root, lock: lock, expectedDescriptor: descriptor)
    }

    /// Internal validation shared by ordinary and leased operations. Ordinary
    /// access can hold a shared lease; only `validate` above requires an
    /// exclusive restore lease for a leased view.
    func validateShared(root expectedRoot: URL, lock expectedLock: URL) throws {
        let root = expectedRoot.standardizedFileURL
        let lock = expectedLock.standardizedFileURL
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let descriptor else {
            throw QuickSurfaceStateStoreError.leaseReleased
        }
        guard root == rootURL.standardizedFileURL,
              lock == lockURL.standardizedFileURL
        else {
            throw QuickSurfaceStateStoreError.leaseRootMismatch
        }
        try validateLive(root: root, lock: lock, expectedDescriptor: descriptor)
    }

    func release() throws {
        stateLock.lock()
        guard let descriptor else {
            stateLock.unlock()
            return
        }
        self.descriptor = nil
        stateLock.unlock()

        let unlockStatus = flock(descriptor, LOCK_UN)
        let unlockError = unlockStatus == 0 ? nil : errno
        let closeStatus = Darwin.close(descriptor)
        if unlockError != nil || closeStatus != 0 {
            throw QuickSurfaceStateStoreError.leaseReleaseFailed
        }
    }

    private func releaseIgnoringErrors() {
        try? release()
    }

    private func validateLive(
        root: URL,
        lock: URL,
        expectedDescriptor: Int32
    ) throws {
        let rootMetadata = try Self.validateRootAndLockParent(root: root, lock: lock)
        guard QuickSurfaceStateStoreFileIdentity(rootMetadata) == rootIdentity else {
            throw QuickSurfaceStateStoreError.leaseIdentityMismatch
        }
        let lockMetadata = try Self.validateDescriptorAndPath(
            descriptor: expectedDescriptor,
            root: root,
            lock: lock
        )
        guard lockMetadata == lockIdentity else {
            throw QuickSurfaceStateStoreError.leaseIdentityMismatch
        }
    }

    private static func openLockFile(at lockURL: URL) throws -> Int32 {
        var descriptor: Int32 = -1
        let represented = lockURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            descriptor = Darwin.open(
                path,
                O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
                mode_t(0o600)
            )
            return true
        }
        guard represented else {
            throw QuickSurfaceStateStoreError.lockFileInvalid
        }
        guard descriptor >= 0 else {
            let code = errno
            switch code {
            case ELOOP:
                throw QuickSurfaceStateStoreError.symlinkDetected
            case EISDIR:
                throw QuickSurfaceStateStoreError.lockFileInvalid
            case EACCES, EPERM:
                throw QuickSurfaceStateStoreError.protectedBeforeFirstUnlock
            case ENOENT, ENOTDIR:
                throw QuickSurfaceStateStoreError.leaseUnavailable
            default:
                throw QuickSurfaceStateStoreError.leaseUnavailable
            }
        }
        return descriptor
    }

    private static func validateRootAndLockParent(
        root: URL,
        lock: URL
    ) throws -> stat {
        guard root.isFileURL, lock.isFileURL else {
            throw QuickSurfaceStateStoreError.invalidRoot
        }
        let rootMetadata = try lstat(at: root)
        guard (rootMetadata.st_mode & S_IFMT) == S_IFDIR else {
            throw QuickSurfaceStateStoreError.unavailableRoot
        }
        guard root.resolvingSymlinksInPath().standardizedFileURL == root else {
            throw QuickSurfaceStateStoreError.symlinkDetected
        }
        try ensureContained(root: root, candidate: lock)

        let rootComponents = root.pathComponents
        let lockComponents = lock.pathComponents
        guard lockComponents.count >= rootComponents.count,
              Array(lockComponents.prefix(rootComponents.count)) == rootComponents
        else {
            throw QuickSurfaceStateStoreError.pathEscape
        }

        var cursor = root
        for component in lockComponents.dropFirst(rootComponents.count).dropLast() {
            cursor.appendPathComponent(component, isDirectory: true)
            let metadata = try lstat(at: cursor)
            guard (metadata.st_mode & S_IFMT) == S_IFDIR else {
                throw QuickSurfaceStateStoreError.invalidRoot
            }
            guard cursor.resolvingSymlinksInPath().standardizedFileURL == cursor else {
                throw QuickSurfaceStateStoreError.symlinkDetected
            }
        }
        return rootMetadata
    }

    private static func validateDescriptorAndPath(
        descriptor: Int32,
        root: URL,
        lock: URL
    ) throws -> QuickSurfaceStateStoreFileIdentity {
        var descriptorMetadata = stat()
        guard Darwin.fstat(descriptor, &descriptorMetadata) == 0 else {
            throw QuickSurfaceStateStoreError.leaseUnavailable
        }
        guard (descriptorMetadata.st_mode & S_IFMT) == S_IFREG,
              descriptorMetadata.st_uid == geteuid(),
              (descriptorMetadata.st_mode & 0o077) == 0,
              descriptorMetadata.st_size == 0
        else {
            throw QuickSurfaceStateStoreError.lockFileInvalid
        }

        let pathMetadata = try lstat(at: lock)
        guard (pathMetadata.st_mode & S_IFMT) == S_IFREG else {
            throw QuickSurfaceStateStoreError.lockFileInvalid
        }
        let descriptorIdentity = QuickSurfaceStateStoreFileIdentity(descriptorMetadata)
        guard descriptorIdentity == QuickSurfaceStateStoreFileIdentity(pathMetadata) else {
            throw QuickSurfaceStateStoreError.leaseIdentityMismatch
        }
        try ensureContained(root: root, candidate: lock)
        guard lock.resolvingSymlinksInPath().standardizedFileURL == lock else {
            throw QuickSurfaceStateStoreError.symlinkDetected
        }
        return descriptorIdentity
    }

    private static func lstat(at url: URL) throws -> stat {
        var metadata = stat()
        let represented = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return Darwin.lstat(path, &metadata) == 0
        }
        guard represented else {
            let code = errno
            if code == ELOOP {
                throw QuickSurfaceStateStoreError.symlinkDetected
            }
            if code == ENOENT || code == ENOTDIR {
                throw QuickSurfaceStateStoreError.leaseUnavailable
            }
            throw QuickSurfaceStateStoreError.leaseUnavailable
        }
        return metadata
    }

    private static func ensureContained(root: URL, candidate: URL) throws {
        let rootComponents = root.standardizedFileURL.pathComponents
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        guard candidateComponents.count >= rootComponents.count,
              Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
        else {
            throw QuickSurfaceStateStoreError.pathEscape
        }
    }
}
