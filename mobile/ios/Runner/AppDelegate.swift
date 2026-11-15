import native_video_player

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Required for flutter_local_notification
    if #available(iOS 10.0, *) {
      UNUserNotificationCenter.current().delegate = self as UNUserNotificationCenterDelegate
    }

    SwiftNativeVideoPlayerPlugin.cookieStorage = URLSessionManager.cookieStorage
    URLSessionManager.patchBackgroundDownloader()
    BackgroundWorkerApiImpl.registerBackgroundWorkers()

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // iOS resumes a suspended app here once the background upload session has drained. Hold ~30 s of
  // background time so Dart can receive the completions and queue the next batch before suspension.
  override func application(
    _ application: UIApplication,
    handleEventsForBackgroundURLSession identifier: String,
    completionHandler: @escaping () -> Void
  ) {
    var task = UIBackgroundTaskIdentifier.invalid
    task = application.beginBackgroundTask(withName: "immich.refill") {
      application.endBackgroundTask(task)
      task = .invalid
    }
    super.application(application, handleEventsForBackgroundURLSession: identifier, completionHandler: completionHandler)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let messenger = engineBridge.applicationRegistrar.messenger()
    AppDelegate.registerPlugins(with: engineBridge.pluginRegistry, messenger: messenger)
    PasskeyHostApiSetup.setUp(binaryMessenger: messenger, api: PasskeyHostApiImpl())
  }

  public static func registerPlugins(with registry: FlutterPluginRegistry, messenger: FlutterBinaryMessenger) {
    NativeSyncApiImpl.register(with: registry.registrar(forPlugin: NativeSyncApiImpl.name)!)
    PermissionApiSetup.setUp(binaryMessenger: messenger, api: PermissionApiImpl())
    LocalImageApiSetup.setUp(binaryMessenger: messenger, api: LocalImageApiImpl())
    RemoteImageApiSetup.setUp(binaryMessenger: messenger, api: RemoteImageApiImpl())
    BackgroundWorkerFgHostApiSetup.setUp(binaryMessenger: messenger, api: BackgroundWorkerApiImpl())
    ConnectivityApiSetup.setUp(binaryMessenger: messenger, api: ConnectivityApiImpl())
    NetworkApiSetup.setUp(binaryMessenger: messenger, api: NetworkApiImpl())
    BackupLiveActivity.register(messenger: messenger)
    BackgroundTime.register(messenger: messenger)
    AssetSizes.register(messenger: messenger)
    UploadExtensionConfig.register(messenger: messenger)
  }

  public static func cancelPlugins(with engine: FlutterEngine) {
    (engine.valuePublished(byPlugin: NativeSyncApiImpl.name) as? NativeSyncApiImpl)?.detachFromEngine()
  }
}
