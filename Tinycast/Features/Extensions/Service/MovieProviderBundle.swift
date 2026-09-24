import Foundation

/// Where the movie root-search provider bundle lives. The bundle (`provider.bundle.js`) is built by
/// the tinycast-tmdb extension (`node Scripts/build-provider.mjs`) into its own build tree; the app
/// only hosts it when the file is actually present, so a build without it degrades to the sync fake
/// provider.
struct MovieProviderBundle {
    static var location: URL {
        URL(fileURLWithPath: "/Users/gregor/code/tinycast-tmdb/build/provider.bundle.js")
        // TODO: resolve relative to this source file (repo root) rather than an absolute path, so the
        // bundle stays colocated with the app build.
    }
}
