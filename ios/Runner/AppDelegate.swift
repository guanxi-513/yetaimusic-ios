import Flutter
import UIKit
import WebKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    // Apple Music 登录：iOS 原生 cookie 提取通道
    // 用 WKWebsiteDataStore.httpCookieStore.getAllCookies 枚举全部 cookie（含 HttpOnly），
    // 解决 iOS 上 document.cookie 读不到完整串的问题（Cider 在 Electron 用 session.cookies.get 同理）
    let channel = FlutterMethodChannel(
      name: "liquid_music/apple_cookies",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    channel.setMethodCallHandler { (call: FlutterMethodCall, result: @escaping FlutterResult) in
      guard call.method == "getAllCookies" else {
        result(FlutterMethodNotImplemented)
        return
      }
      // 关键 cookie 集合（与 Cider 一致）
      let keys = ["itspod", "pltvcid", "pldfltcid", "itua", "media-user-token", "acn1", "dslang"]
      let store = WKWebsiteDataStore.default().httpCookieStore
      store.getAllCookies { cookies in
        var pairs: [String] = []
        var all: [[String: String]] = []
        for cookie in cookies {
          all.append([
            "name": cookie.name,
            "value": cookie.value,
            "domain": cookie.domain,
            "path": cookie.path,
          ])
          if keys.contains(cookie.name) {
            pairs.append("\(cookie.name)=\(cookie.value)")
          }
        }
        result(["pairs": pairs, "all": all])
      }
    }
  }
}
