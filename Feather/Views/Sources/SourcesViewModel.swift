//
//  SourcesViewModel.swift
//  Feather
//
//  Created by samara on 30.04.2025.
//

import Foundation
import AltSourceKit
import SwiftUI
import CryptoKit

// MARK: - Class
@MainActor
final class SourcesViewModel: ObservableObject {
	static let shared = SourcesViewModel()
	
	private let _cacheDirectory = URL.cachesDirectory.appendingPathComponent("FeatherSources", isDirectory: true)

	@Published private(set) var isFinished = true
	@Published var sources: [AltSource: ASRepository] = [:]
	
	func fetchSources(_ sources: FetchedResults<AltSource>, refresh: Bool = false, batchSize: Int = 4) async {
		let entries = sources.compactMap { source in source.sourceURL.map { (source, $0) } }
		self.sources = self.sources.filter { source, _ in entries.contains { $0.0 == source } }
		for (source, url) in entries where self.sources[source] == nil {
			if let cached = try? Data(contentsOf: cacheFile(for: url)),
				let repository = try? JSONDecoder().decode(ASRepository.self, from: cached)
			{
				self.sources[source] = repository
			}
		}
		let pending = entries.filter { _, url in
			refresh || (fetchedAt[url].map { Date().timeIntervalSince($0) >= 1800 } ?? true)
		}
		guard !pending.isEmpty else { return }

		generation += 1
		let run = generation
		isFinished = false
		defer { if run == generation { isFinished = true } }

		for start in stride(from: 0, to: pending.count, by: max(1, batchSize)) {
			guard !Task.isCancelled, run == generation else { return }
			let batch = pending[start..<min(start + max(1, batchSize), pending.count)]
			await withTaskGroup(of: (URL, ASRepository, Data)?.self) { group in
				for (_, url) in batch {
					group.addTask {
						do {
							let (data, response) = try await URLSession.shared.data(from: url)
							guard let response = response as? HTTPURLResponse,
								(200...299).contains(response.statusCode)
							else { return nil }
							return (url, try JSONDecoder().decode(ASRepository.self, from: data), data)
						} catch { return nil }
					}
				}
				for await result in group {
					guard !Task.isCancelled, run == generation else { group.cancelAll(); return }
					if let (url, repository, data) = result, let source = batch.first(where: { $0.1 == url })?.0, !source.isDeleted {
						try? FileManager.default.createDirectoryIfNeeded(at: _cacheDirectory)
						try? data.write(to: cacheFile(for: url), options: .atomic)
						self.sources[source] = repository
						fetchedAt[url] = Date()
					}
				}
			}
		}
	}

	private var generation = 0
	private var fetchedAt: [URL: Date] = [:]

	private func cacheFile(for url: URL) -> URL {
		let key = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
		return _cacheDirectory.appendingPathComponent(key)
	}

	func clearCache() {
		generation += 1
		isFinished = true
		fetchedAt.removeAll()
		try? FileManager.default.removeFileIfNeeded(at: _cacheDirectory)
		sources = [:]
	}
}
