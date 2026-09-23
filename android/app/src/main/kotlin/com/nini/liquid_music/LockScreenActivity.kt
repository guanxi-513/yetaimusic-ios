package com.nini.liquid_music

import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity

/**
 * 锁屏歌词 Activity（网易云/酷狗同款方案）。
 *
 * 悬浮窗（TYPE_APPLICATION_OVERLAY）在 ColorOS/MIUI 上经常不允许显示在
 * 锁屏层；普通 Activity + FLAG_SHOW_WHEN_LOCKED 走正常窗口栈，无需
 * 悬浮窗权限即可显示在锁屏之上，且触摸事件原生可用。
 *
 * 这个 Activity 会启动一个新的 Flutter 引擎并执行 main()，main() 里按
 * defaultRouteName == "lock_lyrics" 分流：只跑歌词 UI，不初始化音频/同步
 * 服务（否则与主引擎重复初始化会打架）。数据/命令走 SharedPreferences
 * 通道（协议见 lock_screen_lyrics_service.dart）。
 */
class LockScreenActivity : FlutterActivity() {
    companion object {
        /** 当前实例（主 isolate 经 MainActivity 调 finishLockScreenActivity 时 finish） */
        @JvmStatic
        var instance: LockScreenActivity? = null
    }

    /** Dart main() 据此分流到歌词 UI */
    override fun getInitialRoute(): String = "lock_lyrics"

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        instance = this
        // ★★★ 关键：显示在锁屏之上 + 歌词显示期间保持屏幕常亮。
        // 注意刻意不加 FLAG_DISMISS_KEYGUARD——那会绕过锁屏，
        // 与"锁屏歌词、不解锁手机"的定位冲突。
        @Suppress("DEPRECATION")
        window.addFlags(
            WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED
                or WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
        }
    }

    override fun onDestroy() {
        if (instance === this) instance = null
        // 通知主 isolate：Activity 已退出（返回键/系统回收），重置显示状态，
        // 否则主端一直认为"已在显示中"，下次亮屏不再弹出
        try {
            getSharedPreferences("FlutterSharedPreferences", MODE_PRIVATE)
                .edit()
                .putLong("flutter.lock_overlay_activity_closed", System.currentTimeMillis())
                .apply()
        } catch (_: Exception) {
        }
        super.onDestroy()
    }
}
