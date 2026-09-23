package com.nini.liquid_music

import android.Manifest
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.BitmapFactory
import android.os.Build
import android.os.Bundle
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.core.content.pm.ShortcutInfoCompat
import androidx.core.content.pm.ShortcutManagerCompat
import androidx.core.graphics.drawable.IconCompat
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/** 必须继承 AudioServiceActivity：为其提供后台共享 FlutterEngine，否则 AudioService.init 抛 PlatformException（白屏） */
class MainActivity : AudioServiceActivity() {
    companion object {
        private const val CHANNEL = "liquid_music/media_notification"
        private const val ICON_CHANNEL = "app_icon"
        private const val LOCK_CHANNEL = "liquid_music/lock_screen"
        private const val REQUEST_NOTIFICATIONS = 100

        // 可切换桌面图标的三个 Activity Alias
        private val ICON_ALIASES = listOf("AliasDefault", "AliasEyes", "AliasSingle")
        private const val CUSTOM_SHORTCUT_ID = "custom_icon_shortcut"
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // 高刷新率适配：请求屏幕支持的最高刷新率模式（flutter_displaymode 的
        // 原生兜底；Build.VERSION_CODES.M = API 23）
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            try {
                val modes = window.windowManager.defaultDisplay?.supportedModes
                val best = modes?.maxByOrNull { it.refreshRate }
                if (best != null) {
                    window.attributes.preferredDisplayModeId = best.modeId
                }
            } catch (_: Exception) {
                // 部分设备 display 未就绪，忽略
            }
        }
        // Android 13+ 运行时申请通知权限（媒体通知必需，首次启动弹一次）
        if (Build.VERSION.SDK_INT >= 33 &&
            ContextCompat.checkSelfPermission(
                this, Manifest.permission.POST_NOTIFICATIONS
            ) != PackageManager.PERMISSION_GRANTED
        ) {
            ActivityCompat.requestPermissions(
                this,
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                REQUEST_NOTIFICATIONS
            )
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger, CHANNEL
        )
        MediaNotificationController.flutterChannel = channel
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "update" -> {
                    MediaNotificationController.update(
                        applicationContext, call.arguments as? Map<*, *>
                    )
                    result.success(null)
                }
                "hide" -> {
                    MediaNotificationController.hide(applicationContext)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        // 应用图标：预设图标切换（Activity Alias）+ 自定义图片桌面快捷方式
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, ICON_CHANNEL)
            .setMethodCallHandler { call, r ->
                when (call.method) {
                    "setIcon" -> {
                        val alias = call.arguments as? String ?: "AliasDefault"
                        r.success(setLauncherIcon(alias))
                    }
                    "getCurrentIcon" -> r.success(currentLauncherIcon())
                    "canPinShortcut" ->
                        r.success(ShortcutManagerCompat.isRequestPinShortcutSupported(this))
                    "pinShortcut" -> {
                        val args = call.arguments as? Map<*, *>
                        val path = args?.get("imagePath") as? String
                        val label = (args?.get("label") as? String) ?: "液态音乐"
                        if (path == null) {
                            r.error("BAD_ARGS", "缺少 imagePath", null)
                        } else {
                            r.success(pinCustomShortcut(path, label))
                        }
                    }
                    else -> r.notImplemented()
                }
            }

        // 锁屏状态监听（锁屏歌词）：SCREEN_OFF/ON + 解锁事件推给 Flutter
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, LOCK_CHANNEL)
            .setMethodCallHandler { call, r ->
                when (call.method) {
                    "start" -> {
                        LockScreenWatcher.start(
                            applicationContext,
                            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, LOCK_CHANNEL)
                        )
                        r.success(true)
                    }
                    "isKeyguardLocked" -> {
                        val km = getSystemService(KEYGUARD_SERVICE) as android.app.KeyguardManager
                        r.success(km.isKeyguardLocked)
                    }
                    // 锁屏歌词：启动/关闭锁屏 Activity（网易云同款方案，
                    // 比 TYPE_APPLICATION_OVERLAY 悬浮窗在各家 ROM 上可靠）
                    "startLockScreenActivity" -> {
                        val intent = Intent(this, LockScreenActivity::class.java)
                        intent.addFlags(
                            Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
                        )
                        startActivity(intent)
                        r.success(true)
                    }
                    "finishLockScreenActivity" -> {
                        LockScreenActivity.instance?.finish()
                        r.success(true)
                    }
                    else -> r.notImplemented()
                }
            }
    }

    /** 启用指定 alias、禁用其余 alias（桌面图标会闪一下，正常现象） */
    private fun setLauncherIcon(alias: String): Boolean {
        if (alias !in ICON_ALIASES) return false
        for (a in ICON_ALIASES) {
            val state = if (a == alias)
                PackageManager.COMPONENT_ENABLED_STATE_ENABLED
            else
                PackageManager.COMPONENT_ENABLED_STATE_DISABLED
            packageManager.setComponentEnabledSetting(
                ComponentName(packageName, "$packageName.$a"),
                state,
                PackageManager.DONT_KILL_APP
            )
        }
        return true
    }

    private fun currentLauncherIcon(): String {
        for (a in ICON_ALIASES) {
            val state = packageManager.getComponentEnabledSetting(
                ComponentName(packageName, "$packageName.$a")
            )
            // DEFAULT（未显式设置过）时只有 AliasDefault 在 manifest 中 enabled
            if (state == PackageManager.COMPONENT_ENABLED_STATE_ENABLED) return a
        }
        return "AliasDefault"
    }

    /** 用自定义图片创建固定桌面快捷方式（Android 8+ 主流启动器支持） */
    private fun pinCustomShortcut(imagePath: String, label: String): Boolean {
        if (!ShortcutManagerCompat.isRequestPinShortcutSupported(this)) return false
        val bitmap = decodeShortcutBitmap(imagePath) ?: return false
        // adaptive bitmap 在 O+ 上可被启动器正常裁剪成圆形/圆角
        val icon = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
            IconCompat.createWithAdaptiveBitmap(bitmap)
        else
            IconCompat.createWithBitmap(bitmap)
        val intent = Intent(Intent.ACTION_VIEW).apply {
            component = ComponentName(packageName, "$packageName.MainActivity")
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val info = ShortcutInfoCompat.Builder(this, CUSTOM_SHORTCUT_ID)
            .setShortLabel(label)
            .setLongLabel(label)
            .setIcon(icon)
            .setIntent(intent)
            .build()
        return ShortcutManagerCompat.requestPinShortcut(this, info, null)
    }

    /** 解码并把自定义图缩到 512px 以内，避免过大 Bitmap */
    private fun decodeShortcutBitmap(path: String) = try {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(path, bounds)
        var sample = 1
        var maxEdge = maxOf(bounds.outWidth, bounds.outHeight)
        while (maxEdge / 2 >= 512) {
            sample *= 2
            maxEdge /= 2
        }
        BitmapFactory.decodeFile(
            path,
            BitmapFactory.Options().apply { inSampleSize = sample }
        )
    } catch (_: Exception) {
        null
    }
}
