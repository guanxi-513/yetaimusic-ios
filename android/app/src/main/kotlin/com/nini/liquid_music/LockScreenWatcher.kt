package com.nini.liquid_music

import android.app.KeyguardManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.util.Log
import io.flutter.plugin.common.MethodChannel

/**
 * 锁屏状态监听（锁屏歌词功能）
 *
 * 动态注册系统广播（SCREEN_OFF / SCREEN_ON / USER_PRESENT），
 * 收到任一事件时把 (screenOn, keyguardLocked) 推给 Flutter。
 * 进程由 audio_service 前台服务保活，锁屏期间 receiver 持续有效。
 *
 * 关键节点输出 android.util.Log（tag=LockScreenWatcher），logcat 可查。
 */
object LockScreenWatcher {
    private const val TAG = "LockScreenWatcher"
    private var receiver: BroadcastReceiver? = null
    private var channel: MethodChannel? = null

    /** 注册广播（幂等，重复调用只更新 channel） */
    fun start(context: Context, ch: MethodChannel) {
        channel = ch
        if (receiver != null) {
            ch.invokeMethod("onWatcherStarted", null)
            return
        }
        val r = object : BroadcastReceiver() {
            override fun onReceive(c: Context, i: Intent) {
                val km =
                    c.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
                val screenOn = i.action != Intent.ACTION_SCREEN_OFF
                Log.d(TAG, "onReceive action=${i.action} keyguard=${km.isKeyguardLocked}")
                try {
                    ch.invokeMethod(
                        "onLockState",
                        mapOf(
                            "screenOn" to screenOn,
                            "keyguard" to km.isKeyguardLocked,
                        )
                    )
                } catch (e: Exception) {
                    Log.w(TAG, "invokeMethod failed: $e")
                }
            }
        }
        receiver = r
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_OFF)
            addAction(Intent.ACTION_SCREEN_ON)
            addAction(Intent.ACTION_USER_PRESENT)
        }
        // Android 13+ 动态注册系统广播必须显式指定 exported 标志
        try {
            if (Build.VERSION.SDK_INT >= 33) {
                context.applicationContext.registerReceiver(
                    r, filter, Context.RECEIVER_EXPORTED
                )
            } else {
                context.applicationContext.registerReceiver(r, filter)
            }
            Log.i(TAG, "receiver registered")
            ch.invokeMethod("onWatcherStarted", null)
        } catch (e: Exception) {
            Log.e(TAG, "registerReceiver failed: $e")
        }
    }
}
