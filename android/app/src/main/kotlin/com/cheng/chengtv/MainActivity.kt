package com.cheng.chengtv

import android.view.KeyEvent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * 把机顶盒/电视遥控器上 Flutter 没有默认映射的按键转发给 Dart 层：
 * 红/绿/黄/蓝功能键、频道加减键、INFO 键。
 */
class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "chengtv/keys")
        // 应用内显示版本号时直接读安装包信息，保证界面版本与 APK 完全一致
        channel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "getVersion" -> {
                    try {
                        val info = packageManager.getPackageInfo(packageName, 0)
                        val code = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.P) {
                            info.longVersionCode
                        } else {
                            @Suppress("DEPRECATION")
                            info.versionCode.toLong()
                        }
                        result.success("${info.versionName} (build $code)")
                    } catch (e: Exception) {
                        result.error("VERSION_ERROR", e.message, null)
                    }
                }
                // 前置摄像头挖孔的精确尺寸（dp）。targetSdk 35+ 在 Android 15 上强制边到边，
                // 内容会铺进挖孔区，Flutter 的 MediaQuery.padding 在沉浸模式下经常报 0，
                // 所以这里直接读 WindowInsets.displayCutout 拿系统给的真实安全区。
                "getDisplayInfo" -> {
                    var l = 0.0
                    var t = 0.0
                    var r = 0.0
                    var b = 0.0
                    try {
                        val density = resources.displayMetrics.density
                        if (density > 0f &&
                            android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.P
                        ) {
                            val cut = window?.decorView?.rootWindowInsets?.displayCutout
                            if (cut != null) {
                                l = (cut.safeInsetLeft / density).toDouble()
                                t = (cut.safeInsetTop / density).toDouble()
                                r = (cut.safeInsetRight / density).toDouble()
                                b = (cut.safeInsetBottom / density).toDouble()
                            }
                        }
                    } catch (_: Exception) {
                    }
                    var smallest = 0
                    try {
                        smallest = resources.configuration.smallestScreenWidthDp
                    } catch (_: Exception) {
                    }
                    result.success(
                        mapOf(
                            "cutoutLeft" to l,
                            "cutoutTop" to t,
                            "cutoutRight" to r,
                            "cutoutBottom" to b,
                            "smallestWidthDp" to smallest
                        )
                    )
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (event.action == KeyEvent.ACTION_DOWN && event.repeatCount == 0) {
            val name = when (event.keyCode) {
                KeyEvent.KEYCODE_PROG_RED -> "color0"
                KeyEvent.KEYCODE_PROG_GREEN -> "color1"
                KeyEvent.KEYCODE_PROG_YELLOW -> "color2"
                KeyEvent.KEYCODE_PROG_BLUE -> "color3"
                KeyEvent.KEYCODE_CHANNEL_UP -> "chUp"
                KeyEvent.KEYCODE_CHANNEL_DOWN -> "chDown"
                KeyEvent.KEYCODE_INFO -> "info"
                else -> null
            }
            if (name != null) {
                channel?.invokeMethod("hardwareKey", name)
                return true
            }
        }
        return super.dispatchKeyEvent(event)
    }
}
