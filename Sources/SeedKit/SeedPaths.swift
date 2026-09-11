import Foundation

/// Local de dados do usuário; override explícito para testes e instalações isoladas.
public enum SeedPaths {
    public static var dataDirectory: URL {
        if let path = ProcessInfo.processInfo.environment["SEED_DATA_DIR"], path.hasPrefix("/") {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Seed")
    }
}
