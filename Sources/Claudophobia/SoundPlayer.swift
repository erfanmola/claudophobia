import AVFoundation

/// Synthesizes the "ding" chimes with AVAudioEngine — no audio assets needed.
/// The app's signature sound is a soft three-note arpeggio with exponential decay.
final class SoundPlayer {
   static let shared = SoundPlayer()

   private let engine = AVAudioEngine()
   private let player = AVAudioPlayerNode()
   private var isRunning = false

   private init() {
      engine.attach(player)
      engine.connect(player, to: engine.mainMixerNode, format: nil)
      do {
         try engine.start()
         isRunning = true
      } catch {
         // Headless / no audio device: keep silent rather than crash.
         isRunning = false
      }
   }

   /// Cheerful ascending arpeggio (C6 → E6 → G6).
   func playDing() {
      play(notes: [(1046.5, 0.00), (1318.5, 0.14), (1568.0, 0.28)])
   }

   /// Gentle two-note "all clear" for quota resets.
   func playReset() {
      play(notes: [(880.0, 0.00), (1108.7, 0.18)])
   }

   private func play(notes: [(frequency: Double, delay: Double)]) {
      guard isRunning else { return }

      let sampleRate = engine.mainMixerNode.outputFormat(forBus: 0).sampleRate
      let totalDuration = 1.0
      let frameCount = AVAudioFrameCount(totalDuration * sampleRate)
      let format = engine.mainMixerNode.outputFormat(forBus: 0)
      guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
         return
      }
      buffer.frameLength = frameCount

      guard let channels = buffer.floatChannelData else { return }
      let channelCount = Int(buffer.format.channelCount)

      // Silence then add notes on every channel.
      for channel in 0..<channelCount {
         memset(channels[channel], 0, Int(buffer.frameLength) * MemoryLayout<Float>.size)
      }

      for note in notes {
         let startSample = Int(note.delay * sampleRate)
         for sample in startSample..<Int(frameCount) {
            let t = Double(sample - startSample) / sampleRate
            let attack = min(t / 0.004, 1.0)
            let decay = exp(-t * 5.5)
            let fundamental = sin(2 * .pi * note.frequency * t)
            let harmonic = sin(2 * .pi * note.frequency * 2 * t) * 0.12
            let value = Float((fundamental + harmonic) * 0.32 * attack * decay)
            for channel in 0..<channelCount {
               channels[channel][sample] += value
            }
         }
      }

      player.scheduleBuffer(buffer, at: nil, options: .interrupts)
      player.play()
   }
}
