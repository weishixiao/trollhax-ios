import Foundation
import AVFoundation
import UIKit

/// 后台任务保活（对齐 OpenMinis 的 BackgroundKeepAliveManager 机制，独立实现）：
/// 流式请求期间开启「有限后台任务 + 静音音频循环」，让 iOS 不挂起 App，
/// AI 回复在切后台后仍能继续接收（用户反馈"后台不会任务进行"）。
/// - 有限后台任务：beginBackgroundTask（约 30s 兜底 + 到期重挂）
/// - 静音音频：AVAudioSourceNode 输出零采样（无感知声音），audio 后台模式生效
///   → 系统不因"无活动"挂起进程
enum BackgroundKeepAlive {
    private static var taskID: UIBackgroundTaskIdentifier = .invalid
    private static var engine: AVAudioEngine?
    private static var started = false
    private static var autoStopWork: DispatchWorkItem?
    private static let lock = NSLock()

    static func start() {
        lock.lock()
        if started { lock.unlock(); return }
        started = true
        lock.unlock()

        // 1) 有限后台任务（到期自动重挂，最长保到流式结束）
        rearmBackgroundTask()

        // 2) 静音音频循环（核心：让系统进入 audio 后台模式，不挂起）
        startSilentAudio()
    }

    static func stop() {
        lock.lock()
        guard started else { lock.unlock(); return }
        started = false
        lock.unlock()

        autoStopWork?.cancel()
        autoStopWork = nil
        if engine?.isRunning == true { engine?.stop() }
        engine = nil
        if taskID != .invalid {
            UIApplication.shared.endBackgroundTask(taskID)
            taskID = .invalid
        }
    }

    private static func rearmBackgroundTask() {
        guard started else { return }
        if taskID != .invalid {
            UIApplication.shared.endBackgroundTask(taskID)
            taskID = .invalid
        }
        taskID = UIApplication.shared.beginBackgroundTask(withName: "TrollHaxStream") {
            // 到期重挂（音频仍在播则再给一段）
            DispatchQueue.main.async {
                if BackgroundKeepAlive.started { BackgroundKeepAlive.rearmBackgroundTask() }
            }
        }
        // 兜底：若 15s 内没有新的流式活动自动停（防音频挂起泄漏）
        let w = DispatchWorkItem { BackgroundKeepAlive.stop() }
        autoStopWork?.cancel()
        autoStopWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: w)
    }

    private static func startSilentAudio() {
        guard engine == nil else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)

            let e = AVAudioEngine()
            let format = AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1)!
            let src = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList -> OSStatus in
                // 输出静音（零采样）
                let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
                for buf in abl {
                    if let m = buf.mData {
                        memset(m, 0, Int(frameCount) * 2)
                        buf.mDataByteSize = UInt32(frameCount) * 2
                    }
                }
                return noErr
            }
            e.attach(src)
            e.connect(src, to: e.mainMixerNode, format: format)
            try e.start()
            engine = e
        } catch {
            engine = nil   // 音频起不来不影响主流程（还有有限后台任务兜底）
        }
    }

    /// 流式有活动时调用（重置自动停倒计时）
    static func poke() {
        rearmBackgroundTask()
    }
}