//
//  BackgroundAudioManager.swift
//  Feather
//
//  Created by Nagata Asami on 12/10/25.
//

#if !targetEnvironment(macCatalyst)

import AVFoundation

class BackgroundAudioManager {
	static let shared = BackgroundAudioManager()
	private let _engine = AVAudioEngine()
	private var owners: Set<String> = []
	private var source: AVAudioSourceNode?
	

	private init() {}
	
	func start(owner: String = "downloads") {
		guard owners.insert(owner).inserted, owners.count == 1 else { return }
		do {
			let session = AVAudioSession.sharedInstance()
			
			try session.setCategory(.playback, options: [.mixWithOthers])
			try session.setActive(true)
			let silence = AVAudioSourceNode { _, _, frameCount, audioBufferList -> OSStatus in
				let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
				for buffer in ablPointer {
					memset(buffer.mData, 0, Int(buffer.mDataByteSize))
				}
				return noErr
			}
			
			source = silence
			_engine.attach(silence)
			_engine.connect(silence, to: _engine.mainMixerNode, format: nil)
			try _engine.start()
		} catch {
			print("failed to start engine:", error)
		}
	}
	
	func stop(owner: String = "downloads") {
		guard owners.remove(owner) != nil, owners.isEmpty else { return }
		_engine.stop()
		if let source {
			_engine.detach(source)
			self.source = nil
		}
		try? AVAudioSession.sharedInstance().setActive(false)
	}
}

#endif
