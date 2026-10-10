import Foundation

/// Local de dados do usuário; override explícito para testes e instalações isoladas.
public enum SeedPaths {
    public static var dataDirectory: URL {
        if let path = ProcessInfo.processInfo.environment["SEED_DATA_DIR"], path.hasPrefix("/") {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return defaultDirectory
    }

    /// Pasta antiga. Saiu de ~/Documents porque o iCloud Drive sincroniza essa
    /// pasta e evicta os arquivos: cada leitura bloqueava até o download e o
    /// áudio da gravação subia para a nuvem enquanto era escrito.
    public static var legacyDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Seed")
    }

    /// ~/Library/Application Support/Seed — resolvido uma vez por processo,
    /// migrando a pasta antiga se ela ainda existir e a nova não.
    private static let defaultDirectory: URL = {
        let fm = FileManager.default
        let target = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Seed")
        if !fm.fileExists(atPath: target.path), fm.fileExists(atPath: legacyDirectory.path) {
            try? fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            do {
                try fm.moveItem(at: legacyDirectory, to: target)
            } catch {
                // migração falhou (offline com arquivos evictados?): segue na
                // pasta antiga em vez de abrir uma biblioteca vazia
                return legacyDirectory
            }
        }
        return target
    }()
}
