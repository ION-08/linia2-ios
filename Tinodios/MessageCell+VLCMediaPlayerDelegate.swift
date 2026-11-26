//
//  MessageViewController+VLCMediaPlayerDelegate.swift
//
//  Copyright © 2022 Tinode LLC. All rights reserved.
//

import AVFAudio
import Foundation
import MobileCoreServices
import MobileVLCKit
import UIKit

extension MessageCell: VLCMediaPlayerDelegate {
    func mediaPlayerStateChanged(_ notification: Notification) {
        guard let player = notification.object as? VLCMediaPlayer else { return }
        // LINIA2: запоздалое событие от плеера, который ячейка уже отпустила (переиспользование).
        guard player === audioPlayer else { return }

        switch player.state {
        case .playing:
            Linia2Playback.shared.claimVoice(cell: self, player: player)
        case .paused:
            Linia2Playback.shared.pausedVoice(player)
        case .opening, .buffering, .esAdded:
            break
        case .error:
            Cache.log.error("MessageCell - media playback failed")
            linia2StopRequested = true
            fallthrough
        case .stopped, .ended:
            // Дослушали до конца (а не остановили сами / не запустили другое) — дальше следующее голосовое ниже.
            let natural = player.state == .ended || !linia2StopRequested
            let seq = seqId
            if mediaEntityKey != nil {
                self.delegate?.didEndMediaPlayback(in: self, audioPlayer: player)
                mediaEntityKey = nil
                Linia2Playback.shared.releaseVoice(player)
                if natural && seq > 0 {
                    (self.delegate as? MessageViewController)?.linia2PlayNextVoice(after: seq)
                }
            } else {
                Linia2Playback.shared.releaseVoice(player)
            }
        default:
            break
        }
    }

    /// LINIA2: остановка по требованию (другое воспроизведение, уход с экрана) — без автоперехода.
    func linia2StopVoice() {
        linia2StopRequested = true
        audioPlayer?.stop()
    }

    func stopAudio() {
        linia2StopRequested = true
        if audioPlayer?.isPlaying ?? false {
            audioPlayer!.stop()
        }
    }

    fileprivate func initAudioPlayer() {
        if audioPlayer == nil {
            audioPlayer = VLCMediaPlayer()
            audioPlayer!.delegate = self
            speakerphone(on: true)
        }
    }

    fileprivate func initMedia(ref: String?, data: Data?, duration: Int, key: Int) {
        if (self.mediaEntityKey ?? -1) == key {
            // Already properly initialized with the same data.
            return
        }
        if let ref = ref, let url = Cache.tinode.toAbsoluteURL(origUrl: ref) {
            audioPlayer!.media = VLCMedia(url: Cache.tinode.addAuthQueryParams(url))
        } else if let data = data {
            audioPlayer!.media = VLCMedia(stream: InputStream(data: data))
        } else {
            Cache.log.info("MessageCell - unable to play audio: no data")
            return
        }

        if audioPlayer!.media!.length.intValue <= 0 && duration > 0 {
            audioPlayer!.media!.length = VLCTime(int: Int32(duration))
        }

        self.mediaEntityKey = key
    }

    func toggleAudioPlay(url: String?, data: Data?, duration: Int, key: Int) {
        initAudioPlayer()

        if audioPlayer!.isPlaying {
            audioPlayer!.pause()
            Linia2Playback.shared.pausedVoice(audioPlayer!)
            self.delegate?.didPauseMedia(in: self, audioPlayer: self.audioPlayer!)
            return
        }

        initMedia(ref: url, data: data, duration: duration, key: key)
        // LINIA2: единый диспетчер — остановить всё остальное до старта.
        linia2StopRequested = false
        Linia2Playback.shared.claimVoice(cell: self, player: audioPlayer!)
        audioPlayer!.play()
        self.delegate?.didActivateMedia(in: self, audioPlayer: self.audioPlayer!)
    }

    func audioSeekTo(_ seekTo: Float, url: String?, data: Data?, duration: Int, key: Int) {
        initAudioPlayer()

        initMedia(ref: url, data: data, duration: duration, key: key)
        var doPause = false
        if !audioPlayer!.isPlaying {
            linia2StopRequested = false
            Linia2Playback.shared.claimVoice(cell: self, player: audioPlayer!)
            Linia2Playback.shared.pausedVoice(audioPlayer!)
            audioPlayer!.play()
            doPause = true
        }
        audioPlayer!.position = seekTo
        if doPause {
            // There is a bug in VLCPLayer: pause() is ignored if called too soon after play().
            // https://code.videolan.org/videolan/VLCKit/-/issues/610
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
                // Async: audioPlayer may have been freed already.
                self.audioPlayer?.pause()
            }
        }
        self.delegate?.didSeekMedia(in: self, audioPlayer: self.audioPlayer!, pos: seekTo)
    }

    private func speakerphone(on: Bool) {
        let session = AVAudioSession.sharedInstance()
        // LINIA2: идёт звонок — его аудиосессию не трогаем.
        if session.mode == .voiceChat || session.mode == .videoChat { return }
        if on {
            do {
                try session.setCategory(AVAudioSession.Category.playAndRecord)
                try session.setActive(true)
                try session.overrideOutputAudioPort(AVAudioSession.PortOverride.speaker)
            } catch let error as NSError {
                Cache.log.error("Failed to enable speakerphone: %@", error.localizedDescription)
            }
        } else {
            do {
                try session.setActive(false)
            } catch let error as NSError {
                Cache.log.error("Failed to disable audio session: %@", error.localizedDescription)
            }
        }
    }
}

// MARK: - LINIA2: единый диспетчер воспроизведения

/// Одновременно играет только одно голосовое ИЛИ один видео-кружок. Запуск нового останавливает текущее.
/// Аудиосессию звонка не трогает (только останавливает свои плееры).
final class Linia2Playback {
    static let shared = Linia2Playback()
    /// Сменилось то, что играет (для значков и VoiceOver в ленте).
    static let changed = Notification.Name("linia2.playback.changed")

    private weak var voiceCell: MessageCell?
    private weak var voicePlayer: VLCMediaPlayer?
    private var voicePaused = false
    private weak var round: Linia2RoundVideoView?
    /// seq голосового, которое сейчас звучит (0 — ничего).
    private(set) var voiceSeq = 0

    private init() {
        // Приложение ушло в фон — кружок останавливается.
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.stopRound()
        }
    }

    /// Голосовое этого seq сейчас звучит (не на паузе).
    func isVoicePlaying(seq: Int) -> Bool { seq > 0 && voiceSeq == seq && voicePlayer != nil && !voicePaused }

    func claimVoice(cell: MessageCell, player: VLCMediaPlayer) {
        if let r = round {
            round = nil
            r.pause()
        }
        if let p = voicePlayer, p !== player {
            let c = voiceCell
            voicePlayer = nil
            voiceCell = nil
            if let c = c, c.audioPlayer === p { c.linia2StopVoice() } else { p.stop() }
        }
        let changed = voicePlayer !== player || voicePaused || voiceSeq != cell.seqId
        voiceCell = cell
        voicePlayer = player
        voicePaused = false
        voiceSeq = cell.seqId
        if changed { post() }
    }

    func pausedVoice(_ player: VLCMediaPlayer) {
        guard voicePlayer === player, !voicePaused else { return }
        voicePaused = true
        post()
    }

    func releaseVoice(_ player: VLCMediaPlayer) {
        guard voicePlayer === player else { return }
        voicePlayer = nil
        voiceCell = nil
        voiceSeq = 0
        voicePaused = false
        post()
    }

    func claimRound(_ r: Linia2RoundVideoView) {
        stopVoice()
        if let o = round, o !== r { o.pause() }
        round = r
        post()
    }

    func releaseRound(_ r: Linia2RoundVideoView) {
        guard round === r else { return }
        round = nil
        post()
    }

    func stopVoice() {
        guard let p = voicePlayer else { return }
        let c = voiceCell
        voicePlayer = nil
        voiceCell = nil
        voiceSeq = 0
        voicePaused = false
        if let c = c, c.audioPlayer === p { c.linia2StopVoice() } else { p.stop() }
        post()
    }

    func stopRound() {
        round?.pause()
    }

    /// Уход с экрана чата: всё стоп.
    func stopAll() {
        stopVoice()
        stopRound()
    }

    private func post() {
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }
}
