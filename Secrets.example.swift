// Template for Shared/Secrets.swift (which is gitignored).
//
// Local setup:
//   cp Secrets.example.swift Shared/Secrets.swift
// then paste your transit.accessibility.cloud appToken below (issued by
// Sozialhelden for the new transit API — the old www.accessibility.cloud
// token does not work against it).
//
// This file lives at the repo root on purpose: it must NOT sit inside a
// PBXFileSystemSynchronizedRootGroup (Shared/, Hissi/, …), or it would be
// auto-compiled and clash with the real Secrets enum.
import Foundation

enum Secrets {
    // nonisolated: the project defaults to MainActor isolation
    // (SWIFT_DEFAULT_ACTOR_ISOLATION), but this constant is read from
    // nonisolated networking code, so keep it actor-independent.
    nonisolated static let accessibilityCloudAppToken = ""
}
