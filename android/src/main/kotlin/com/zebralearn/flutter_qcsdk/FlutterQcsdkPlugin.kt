package com.zebralearn.flutter_qcsdk

import android.app.Activity
import android.app.Application
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothProfile
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.provider.Settings
import android.net.wifi.WifiManager
import android.graphics.BitmapFactory
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.localbroadcastmanager.content.LocalBroadcastManager
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

import com.oudmon.ble.base.bluetooth.BleAction
import com.oudmon.ble.base.bluetooth.BleBaseControl
import com.oudmon.ble.base.bluetooth.BleOperateManager
import com.oudmon.ble.base.bluetooth.DeviceManager
import com.oudmon.ble.base.bluetooth.QCBluetoothCallbackCloneReceiver
import com.oudmon.ble.base.communication.Constants
import com.oudmon.ble.base.communication.LargeDataHandler
import com.oudmon.ble.base.communication.ILargeDataResponse
import com.oudmon.ble.base.communication.bigData.resp.GlassesDeviceNotifyListener
import com.oudmon.ble.base.communication.bigData.resp.GlassesDeviceNotifyRsp
import com.oudmon.ble.base.communication.bigData.resp.BatteryResponse
import com.oudmon.ble.base.communication.bigData.resp.DeviceInfoResponse
import com.oudmon.ble.base.communication.bigData.resp.VolumeControlResponse
import com.oudmon.ble.base.communication.bigData.resp.GlassesAiVoiceRsp
import com.oudmon.ble.base.communication.bigData.resp.GlassesWearRsp
import com.oudmon.ble.base.communication.bigData.resp.GlassModelControlResponse
import com.oudmon.ble.base.communication.bigData.resp.AiChatResponse
import com.oudmon.ble.base.communication.bigData.resp.PictureThumbnailsResponse
import com.oudmon.ble.base.communication.utils.ByteUtil
import com.oudmon.ble.base.scan.BleScannerHelper
import com.oudmon.ble.base.scan.ScanRecord
import com.oudmon.ble.base.scan.ScanWrapperCallback
import com.oudmon.wifi.GlassesControl
import com.oudmon.wifi.bean.GlassAlbumEntity

import android.media.MediaCodec
import android.media.MediaFormat
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.Arrays

class FlutterQcsdkPlugin: FlutterPlugin, MethodCallHandler, EventChannel.StreamHandler, ActivityAware {
    private val TAG = "FlutterQcsdkPlugin"
    private lateinit var channel : MethodChannel
    private lateinit var eventChannel: EventChannel
    private var context: Context? = null
    private var activity: Activity? = null
    private var application: Application? = null
    private var eventSink: EventChannel.EventSink? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    private val scannedDevices = mutableMapOf<String, Map<String, Any>>()

    private var hardwareVersion: String = ""
    private var firmwareVersion: String = ""

    private var myBleReceiver: PluginBleReceiver? = null
    private var systemBluetoothReceiver: BroadcastReceiver? = null

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        context = flutterPluginBinding.applicationContext
        channel = MethodChannel(flutterPluginBinding.binaryMessenger, "flutter_qcsdk/methods")
        channel.setMethodCallHandler(this)

        eventChannel = EventChannel(flutterPluginBinding.binaryMessenger, "flutter_qcsdk/events")
        eventChannel.setStreamHandler(this)

        initializeSdk(flutterPluginBinding.applicationContext)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        context?.let { cleanupSdk(it) }
        context = null
        application = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivity() {
        activity = null
    }

    private fun initializeSdk(context: Context) {
        val app = context.applicationContext as Application
        this.application = app

        LargeDataHandler.getInstance()
        BleOperateManager.getInstance(app)
        BleOperateManager.getInstance().setApplication(app)
        BleOperateManager.getInstance().init()
        BleOperateManager.getInstance().setNeedConnect(false)

        // Register local BLE broadcast receiver
        myBleReceiver = PluginBleReceiver()
        val intentFilter = BleAction.getIntentFilter()
        LocalBroadcastManager.getInstance(context).registerReceiver(myBleReceiver!!, intentFilter)
        BleBaseControl.getInstance(context).setmContext(app)

        // Register system Bluetooth receiver
        systemBluetoothReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                val action = intent.action
                if (BluetoothAdapter.ACTION_STATE_CHANGED == action) {
                    val state = intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, -1)
                    val stateVal = when (state) {
                        BluetoothAdapter.STATE_ON -> 5 // poweredOn
                        BluetoothAdapter.STATE_OFF -> 4 // poweredOff
                        else -> 0 // unknown
                    }
                    mainHandler.post {
                        eventSink?.success(mapOf(
                            "type" to "bluetoothState",
                            "state" to stateVal
                        ))
                    }
                    if (state == BluetoothAdapter.STATE_OFF) {
                        BleOperateManager.getInstance().setNeedConnect(false)
                        BleOperateManager.getInstance().setBluetoothTurnOff(false)
                        BleOperateManager.getInstance().disconnect()
                        BleOperateManager.getInstance().isReady = false
                        mainHandler.removeCallbacksAndMessages(null)
                        mainHandler.post {
                            eventSink?.success(mapOf(
                                "type" to "deviceState",
                                "state" to 5 // disconnected
                            ))
                        }
                    } else if (state == BluetoothAdapter.STATE_ON) {
                        BleOperateManager.getInstance().setBluetoothTurnOff(true)
                        BleOperateManager.getInstance().setNeedConnect(false)
                    }
                } else if (BluetoothDevice.ACTION_ACL_DISCONNECTED == action) {
                    val device = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java)
                    } else {
                        @Suppress("DEPRECATION")
                        intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)
                    }
                    val targetAddress = DeviceManager.getInstance().deviceAddress
                    if (device != null && !targetAddress.isNullOrEmpty() && device.address.equals(targetAddress, ignoreCase = true)) {
                        Log.i(TAG, "👓 [SYSTEM BLE] ACL disconnected for specs device: ${device.address}")
                        BleOperateManager.getInstance().setNeedConnect(false)
                        BleOperateManager.getInstance().isReady = false
                        BleOperateManager.getInstance().disconnect()
                        mainHandler.removeCallbacksAndMessages(null)
                        mainHandler.post {
                            eventSink?.success(mapOf(
                                "type" to "deviceState",
                                "state" to 5 // disconnected
                            ))
                        }
                    }
                }
            }
        }
        val deviceFilter = IntentFilter().apply {
            addAction(BluetoothAdapter.ACTION_STATE_CHANGED)
            addAction(BluetoothDevice.ACTION_BOND_STATE_CHANGED)
            addAction(BluetoothDevice.ACTION_ACL_CONNECTED)
            addAction(BluetoothDevice.ACTION_ACL_DISCONNECTED)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            context.registerReceiver(systemBluetoothReceiver, deviceFilter, Context.RECEIVER_EXPORTED)
        } else {
            context.registerReceiver(systemBluetoothReceiver, deviceFilter)
        }

        // Add out device notification listener
        LargeDataHandler.getInstance().addOutDeviceListener(100, deviceNotifyListener)

        // Register GPT Chat listener
        LargeDataHandler.getInstance().initPackageNotify { cmdType, response ->
            if (response is AiChatResponse) {
                val subData = response.subData
                if (subData != null && subData.size > 6) {
                    val type = subData[6].toInt()
                    val payload = subData.copyOfRange(7, subData.size)
                    when (type) {
                        0x01 -> {
                            val text = String(payload, Charsets.UTF_8)
                            mainHandler.post {
                                eventSink?.success(mapOf(
                                    "type" to "aiChatText",
                                    "message" to text
                                ))
                            }
                        }
                        0x02 -> {
                            mainHandler.post {
                                eventSink?.success(mapOf(
                                    "type" to "aiChatVoice",
                                    "data" to payload
                                ))
                            }
                        }
                        0x03 -> {
                            mainHandler.post {
                                eventSink?.success(mapOf(
                                    "type" to "aiChatImage",
                                    "data" to payload
                                ))
                            }
                        }
                    }
                }
            }
        }
    }

    private fun cleanupSdk(context: Context) {
        myBleReceiver?.let {
            LocalBroadcastManager.getInstance(context).unregisterReceiver(it)
        }
        systemBluetoothReceiver?.let {
            context.unregisterReceiver(it)
        }
        LargeDataHandler.getInstance().removeOutDeviceListener(100)
        LargeDataHandler.getInstance().removeGptNotify()
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        this.eventSink = events
        // Immediately notify current bluetooth and connection states on startup/subscription
        mainHandler.post {
            try {
                val btAdapter = BluetoothAdapter.getDefaultAdapter()
                val btState = if (btAdapter != null && btAdapter.isEnabled) 5 else 4
                events?.success(mapOf(
                    "type" to "bluetoothState",
                    "state" to btState
                ))

                val isConnected = BleOperateManager.getInstance().isConnected
                if (isConnected) {
                    events?.success(mapOf(
                        "type" to "deviceState",
                        "state" to 3 // connected
                    ))
                } else {
                    events?.success(mapOf(
                        "type" to "deviceState",
                        "state" to 5 // disconnected
                    ))
                }
            } catch (e: Exception) {
                // ignore
            }
        }
    }

    override fun onCancel(arguments: Any?) {
        this.eventSink = null
    }

    private class SafeResult(private val target: Result) : Result {
        private val hasReplied = java.util.concurrent.atomic.AtomicBoolean(false)

        override fun success(result: Any?) {
            if (hasReplied.compareAndSet(false, true)) {
                target.success(result)
            }
        }

        override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
            if (hasReplied.compareAndSet(false, true)) {
                target.error(errorCode, errorMessage, errorDetails)
            }
        }

        override fun notImplemented() {
            if (hasReplied.compareAndSet(false, true)) {
                target.notImplemented()
            }
        }
    }

    override fun onMethodCall(call: MethodCall, rawResult: Result) {
        val result = SafeResult(rawResult)
        when (call.method) {
            "requestEnableBluetooth" -> {
                try {
                    val act = activity
                    if (act != null) {
                        val intent = Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE)
                        act.startActivity(intent)
                        result.success(true)
                    } else {
                        val intent = Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE).apply {
                            flags = Intent.FLAG_ACTIVITY_NEW_TASK
                        }
                        context?.startActivity(intent)
                        result.success(true)
                    }
                } catch (e: Exception) {
                    result.error("ERROR", e.message, null)
                }
            }
            "openBluetoothSettings" -> {
                try {
                    val intent = Intent(Settings.ACTION_BLUETOOTH_SETTINGS)
                    intent.flags = Intent.FLAG_ACTIVITY_NEW_TASK
                    context?.startActivity(intent)
                    result.success(true)
                } catch (e: Exception) {
                    result.error("ERROR", e.message, null)
                }
            }
            "openLocationSettings" -> {
                try {
                    val intent = Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS)
                    intent.flags = Intent.FLAG_ACTIVITY_NEW_TASK
                    context?.startActivity(intent)
                    result.success(true)
                } catch (e: Exception) {
                    result.error("ERROR", e.message, null)
                }
            }
            "openWifiSettings" -> {
                try {
                    val intent = Intent(Settings.ACTION_WIFI_SETTINGS)
                    intent.flags = Intent.FLAG_ACTIVITY_NEW_TASK
                    context?.startActivity(intent)
                    result.success(true)
                } catch (e: Exception) {
                    result.error("ERROR", e.message, null)
                }
            }
            "isWifiEnabled" -> {
                try {
                    val wifiManager = context?.applicationContext?.getSystemService(Context.WIFI_SERVICE) as? WifiManager
                    val isEnabled = wifiManager?.isWifiEnabled ?: false
                    result.success(isEnabled)
                } catch (e: Exception) {
                    result.success(true)
                }
            }
            "getDeviceState" -> {
                val isConnected = try {
                    BleOperateManager.getInstance().isConnected
                } catch (e: Exception) {
                    false
                }
                val state = if (isConnected) 3 else 5
                result.success(state)
            }
            "isDeviceConnected" -> {
                val isConnected = try {
                    BleOperateManager.getInstance().isConnected
                } catch (e: Exception) {
                    false
                }
                result.success(isConnected)
            }
            "getConnectedDevice" -> {
                try {
                    val isConnected = BleOperateManager.getInstance().isConnected
                    if (isConnected) {
                        val address = DeviceManager.getInstance().deviceAddress ?: ""
                        val name = DeviceManager.getInstance().deviceName ?: "Smart Specs"
                        result.success(mapOf(
                            "name" to name,
                            "identifier" to address,
                            "mac" to address,
                            "rssi" to 0,
                            "isPaired" to true
                        ))
                    } else {
                        result.success(null)
                    }
                } catch (e: Exception) {
                    result.success(null)
                }
            }
            "startScan" -> {
                scannedDevices.clear()
                BleScannerHelper.getInstance().reSetCallback()
                val scanCallback = object : ScanWrapperCallback {
                    override fun onStart() {}
                    override fun onStop() {}
                    override fun onLeScan(device: BluetoothDevice?, rssi: Int, scanRecord: ByteArray?) {
                        if (device != null) {
                            val address = device.address ?: return
                            val parsedName = extractLocalName(scanRecord)
                            val name = if (!device.name.isNullOrEmpty()) device.name else parsedName
                            if (name.isNullOrEmpty()) return

                            val isPaired = device.bondState == BluetoothDevice.BOND_BONDED
                            val hasSpecsSignature = checkSpecsSignature(scanRecord)

                            val deviceMap = mapOf(
                                "name" to name,
                                "identifier" to address,
                                "mac" to address,
                                "rssi" to rssi,
                                "isPaired" to isPaired,
                                "hasSpecsSignature" to hasSpecsSignature
                            )
                            scannedDevices[address] = deviceMap
                            mainHandler.post {
                                eventSink?.success(mapOf(
                                    "type" to "scanResults",
                                    "peripherals" to scannedDevices.values.toList()
                                ))
                            }
                        }
                    }
                    override fun onScanFailed(errorCode: Int) {}
                    override fun onParsedData(device: BluetoothDevice?, scanRecord: ScanRecord?) {}
                    override fun onBatchScanResults(results: MutableList<android.bluetooth.le.ScanResult>?) {}
                }
                BleScannerHelper.getInstance().scanDevice(context, null, scanCallback)
                result.success(null)
            }
            "stopScan" -> {
                BleScannerHelper.getInstance().stopScan(context)
                result.success(null)
            }
            "connect" -> {
                val identifier = call.argument<String>("identifier")
                if (identifier != null) {
                    BleOperateManager.getInstance().setNeedConnect(false)
                    DeviceManager.getInstance().deviceAddress = identifier
                    BleOperateManager.getInstance().connectDirectly(identifier)
                    result.success(null)
                } else {
                    result.error("INVALID_ARGUMENT", "Identifier is null", null)
                }
            }
            "disconnect" -> {
                BleOperateManager.getInstance().setNeedConnect(false)
                BleOperateManager.getInstance().isReady = false
                BleOperateManager.getInstance().disconnect()
                mainHandler.removeCallbacksAndMessages(null)
                mainHandler.post {
                    eventSink?.success(mapOf(
                        "type" to "deviceState",
                        "state" to 5 // disconnected
                    ))
                }
                result.success(null)
            }
            "unpair" -> {
                BleOperateManager.getInstance().setNeedConnect(false)
                BleOperateManager.getInstance().unBindDevice()
                DeviceManager.getInstance().deviceAddress = null
                DeviceManager.getInstance().deviceName = null
                mainHandler.removeCallbacksAndMessages(null)
                mainHandler.post {
                    eventSink?.success(mapOf(
                        "type" to "deviceState",
                        "state" to 1 // unbind
                    ))
                }
                result.success(null)
            }
            "setDeviceMode" -> {
                val modeVal = call.argument<Int>("mode") ?: 0
                val cmdData = byteArrayOf(0x02, 0x01, modeVal.toByte())
                LargeDataHandler.getInstance().glassesControl(cmdData) { _, response ->
                    if (response != null && response.errorCode == 0) {
                        mainHandler.post { result.success(null) }
                    } else {
                        mainHandler.post { result.error("ERROR", "Failed to set device mode", response?.errorCode) }
                    }
                }
            }
            "openWifiWithMode" -> {
                val modeVal = call.argument<Int>("mode") ?: 0
                val cmdData = byteArrayOf(0x02, 0x01, 0x04) // mode 4 is transfer (Wi-Fi)
                LargeDataHandler.getInstance().glassesControl(cmdData) { _, response ->
                    if (response != null && response.errorCode == 0) {
                        val wifiName = DeviceManager.getInstance().wifiName ?: ""
                        val wifiPassword = DeviceManager.getInstance().wifiPassword ?: "123456789"
                        mainHandler.post {
                            result.success(mapOf("ssid" to wifiName, "password" to wifiPassword))
                        }
                    } else {
                        mainHandler.post { result.error("ERROR", "Failed to open WiFi", response?.errorCode) }
                    }
                }
            }
            "setVideoInfo" -> {
                val angle = call.argument<Int>("angle") ?: 0
                val duration = call.argument<Int>("duration") ?: 0
                val cmdData = byteArrayOf(0x02, 0x02, angle.toByte(), (duration and 0xff).toByte(), ((duration shr 8) and 0xff).toByte())
                LargeDataHandler.getInstance().glassesControl(cmdData) { _, response ->
                    if (response != null && response.errorCode == 0) {
                        mainHandler.post { result.success(null) }
                    } else {
                        mainHandler.post { result.error("ERROR", "Failed to set video info", null) }
                    }
                }
            }
            "getVideoInfo" -> {
                val cmdData = byteArrayOf(0x02, 0x02)
                LargeDataHandler.getInstance().glassesControl(cmdData) { _, response ->
                    if (response != null) {
                        mainHandler.post {
                            result.success(mapOf(
                                "angle" to response.videoAngle,
                                "duration" to response.videoDuration
                            ))
                        }
                    } else {
                        mainHandler.post { result.error("ERROR", "Failed to get video info", null) }
                    }
                }
            }
            "getDeviceWifiIP" -> {
                val cmdData = byteArrayOf(0x02, 0x03)
                LargeDataHandler.getInstance().glassesControl(cmdData) { _, response ->
                    if (response != null) {
                        mainHandler.post { result.success(response.p2pIp) }
                    } else {
                        mainHandler.post { result.error("ERROR", "Failed to get device WiFi IP", null) }
                    }
                }
            }
            "getDeviceMedia" -> {
                val cmdData = byteArrayOf(0x02, 0x04)
                LargeDataHandler.getInstance().glassesControl(cmdData) { _, response ->
                    if (response != null) {
                        val photoCount = response.imageCount
                        val videoCount = response.videoCount
                        val audioCount = response.recordCount
                        val totalCount = photoCount + videoCount + audioCount
                        Log.i("FlutterQcsdk", "👓 [SPECS MEDIA INFO] Total items on glasses: $totalCount -> Photos: $photoCount, Videos: $videoCount, Audio: $audioCount")
                        mainHandler.post {
                            result.success(mapOf(
                                "photoCount" to photoCount,
                                "videoCount" to videoCount,
                                "audioCount" to audioCount,
                                "totalSize" to 0
                            ))
                        }
                    } else {
                        Log.e("FlutterQcsdk", "❌ [SPECS MEDIA INFO ERROR] Failed to get device media count from glasses")
                        mainHandler.post { result.error("ERROR", "Failed to get device media count", null) }
                    }
                }
            }
            "deleteAllMedias" -> {
                val cmdData = byteArrayOf(0x02, 0x05)
                LargeDataHandler.getInstance().glassesControl(cmdData) { _, response ->
                    Log.i("FlutterQcsdk", "🧹 [SPECS DELETE ALL] glassesControl(0x02, 0x05) response: ${response?.errorCode}")
                    mainHandler.post {
                        eventSink?.success(mapOf(
                            "type" to "mediaUpdate",
                            "photoCount" to 0,
                            "videoCount" to 0,
                            "audioCount" to 0,
                            "mediaType" to 0
                        ))
                        result.success(null)
                    }
                }
            }
            "deleteMedia" -> {
                result.success(null)
            }
            "setAudioInfo" -> {
                val angle = call.argument<Int>("angle") ?: 0
                val duration = call.argument<Int>("duration") ?: 0
                val cmdData = byteArrayOf(0x02, 0x06, angle.toByte(), (duration and 0xff).toByte(), ((duration shr 8) and 0xff).toByte())
                LargeDataHandler.getInstance().glassesControl(cmdData) { _, response ->
                    if (response != null && response.errorCode == 0) {
                        mainHandler.post { result.success(null) }
                    } else {
                        mainHandler.post { result.error("ERROR", "Failed to set audio info", null) }
                    }
                }
            }
            "getAudioInfo" -> {
                val cmdData = byteArrayOf(0x02, 0x06)
                LargeDataHandler.getInstance().glassesControl(cmdData) { _, response ->
                    if (response != null) {
                        mainHandler.post {
                            result.success(mapOf(
                                "angle" to 0,
                                "duration" to response.recordAudioDuration
                            ))
                        }
                    } else {
                        mainHandler.post { result.error("ERROR", "Failed to get audio info", null) }
                    }
                }
            }
            "getDeviceBattery" -> {
                val key = "method_call_" + System.currentTimeMillis()
                LargeDataHandler.getInstance().addBatteryCallBack(key) { _, response ->
                    LargeDataHandler.getInstance().removeBatteryCallBack(key)
                    if (response != null) {
                        mainHandler.post {
                            result.success(mapOf(
                                "battery" to response.battery,
                                "charging" to response.isCharging
                            ))
                        }
                    } else {
                        mainHandler.post { result.error("ERROR", "Failed to get battery status", null) }
                    }
                }
                LargeDataHandler.getInstance().syncBattery()
            }
            "getDeviceVersionInfo" -> {
                LargeDataHandler.getInstance().syncDeviceInfo { _, response ->
                    if (response != null) {
                        mainHandler.post {
                            result.success(mapOf(
                                "hardwareVersion" to (response.hardwareVersion ?: ""),
                                "firmwareVersion" to (response.firmwareVersion ?: ""),
                                "hardwareWifiVersion" to (response.wifiHardwareVersion ?: ""),
                                "firmwareWifiVersion" to (response.wifiFirmwareVersion ?: "")
                            ))
                        }
                    } else {
                        mainHandler.post { result.error("ERROR", "Failed to get version info", null) }
                    }
                }
            }
            "isPeripheralFreeNow" -> {
                result.success(BleOperateManager.getInstance().isReady)
            }
            "setupDeviceDateTime" -> {
                LargeDataHandler.getInstance().syncTime { _, response ->
                    if (response != null) {
                        mainHandler.post { result.success(null) }
                    } else {
                        mainHandler.post { result.error("ERROR", "Failed to sync date time", null) }
                    }
                }
            }
            "getThumbnail" -> {
                val pocket = call.argument<Int>("pocket") ?: 0
                val handler = LargeDataHandler.getInstance()

                // Register ACTION_PICTURE_THUMBNAILS (0xfd) custom handler in respMap
                handler.respMap.put(0xfd.toInt(), object : ILargeDataResponse<PictureThumbnailsResponse> {
                    override fun parseData(cmdType: Int, response: PictureThumbnailsResponse?) {
                        if (response != null) {
                            val subData = response.subData
                            if (subData != null && subData.size > 11) {
                                val total = ByteUtil.bytesToInt(Arrays.copyOfRange(subData, 7, 9))
                                val currIndex = ByteUtil.bytesToInt(Arrays.copyOfRange(subData, 9, 11))
                                val imgBytes = Arrays.copyOfRange(subData, 11, subData.size)

                                val options = BitmapFactory.Options().apply {
                                    inJustDecodeBounds = true
                                }
                                BitmapFactory.decodeByteArray(imgBytes, 0, imgBytes.size, options)
                                val w = options.outWidth
                                val h = options.outHeight

                                mainHandler.post {
                                    result.success(mapOf(
                                        "data" to imgBytes,
                                        "width" to w,
                                        "height" to h
                                    ))
                                }
                            } else {
                                mainHandler.post { result.error("ERROR", "Invalid thumbnail packet", null) }
                            }
                        } else {
                            mainHandler.post { result.error("ERROR", "Failed to get thumbnail", null) }
                        }
                    }
                })

                // Invoke private syncPictureThumbnails(pocket) via reflection
                try {
                    val method = handler.javaClass.getDeclaredMethod("syncPictureThumbnails", Int::class.javaPrimitiveType)
                    method.isAccessible = true
                    method.invoke(handler, pocket)
                } catch (e: Exception) {
                    handler.getPictureThumbnails { _, success, data ->
                        if (success && data != null) {
                            val options = BitmapFactory.Options().apply {
                                inJustDecodeBounds = true
                            }
                            BitmapFactory.decodeByteArray(data, 0, data.size, options)
                            val w = options.outWidth
                            val h = options.outHeight
                            mainHandler.post {
                                result.success(mapOf(
                                    "data" to data,
                                    "width" to w,
                                    "height" to h
                                ))
                            }
                        } else {
                            mainHandler.post { result.error("ERROR", "Reflection & fallback failed to get thumbnail", null) }
                        }
                    }
                }
            }
            "sendVoiceHeartbeat" -> {
                LargeDataHandler.getInstance().syncHeartBeat(1)
                result.success(null)
            }
            "getVoiceWakeup" -> {
                LargeDataHandler.getInstance().aiVoiceWake(false, false) { _, response ->
                    if (response != null) {
                        mainHandler.post { result.success(response.isOpen) }
                    } else {
                        mainHandler.post { result.error("ERROR", "Failed to get voice wakeup status", null) }
                    }
                }
            }
            "setVoiceWakeup" -> {
                val isOn = call.argument<Boolean>("isOn") ?: false
                LargeDataHandler.getInstance().aiVoiceWake(true, isOn) { _, response ->
                    if (response != null) {
                        mainHandler.post { result.success(response.isOpen) }
                    } else {
                        mainHandler.post { result.error("ERROR", "Failed to set voice wakeup status", null) }
                    }
                }
            }
            "getWearingDetection" -> {
                LargeDataHandler.getInstance().wearCheck(false, false) { _, response ->
                    if (response != null) {
                        mainHandler.post { result.success(response.isOpen) }
                    } else {
                        mainHandler.post { result.error("ERROR", "Failed to get wearing detection status", null) }
                    }
                }
            }
            "setWearingDetection" -> {
                val isOn = call.argument<Boolean>("isOn") ?: false
                LargeDataHandler.getInstance().wearCheck(true, isOn) { _, response ->
                    if (response != null) {
                        mainHandler.post { result.success(response.isOpen) }
                    } else {
                        mainHandler.post { result.error("ERROR", "Failed to set wearing detection status", null) }
                    }
                }
            }
            "getDeviceConfig" -> {
                result.success(null)
            }
            "setAISpeekModel" -> {
                val speakMode = call.argument<Int>("speakMode") ?: 1
                val playOnPhone = (speakMode == 3)
                LargeDataHandler.getInstance().speakSoundSwitch(playOnPhone)
                result.success(null)
            }
            "getVolume" -> {
                LargeDataHandler.getInstance().getVolumeControl { _, response ->
                    if (response != null) {
                        mainHandler.post {
                            result.success(mapOf(
                                "musicMin" to response.minVolumeMusic,
                                "musicMax" to response.maxVolumeMusic,
                                "musicCurrent" to response.currVolumeMusic,
                                "callMin" to response.minVolumeCall,
                                "callMax" to response.maxVolumeCall,
                                "callCurrent" to response.currVolumeCall,
                                "systemMin" to response.minVolumeSystem,
                                "systemMax" to response.maxVolumeSystem,
                                "systemCurrent" to response.currVolumeSystem,
                                "mode" to response.currVolumeType
                            ))
                        }
                    } else {
                        mainHandler.post { result.error("ERROR", "Failed to get volume settings", null) }
                    }
                }
            }
            "setVolume" -> {
                val musicMin = call.argument<Int>("musicMin") ?: 0
                val musicMax = call.argument<Int>("musicMax") ?: 15
                val musicCurrent = call.argument<Int>("musicCurrent") ?: 7
                val callMin = call.argument<Int>("callMin") ?: 0
                val callMax = call.argument<Int>("callMax") ?: 15
                val callCurrent = call.argument<Int>("callCurrent") ?: 7
                val systemMin = call.argument<Int>("systemMin") ?: 0
                val systemMax = call.argument<Int>("systemMax") ?: 15
                val systemCurrent = call.argument<Int>("systemCurrent") ?: 7
                val mode = call.argument<Int>("mode") ?: 1

                LargeDataHandler.getInstance().setVolumeControl(
                    musicMin, musicMax, musicCurrent,
                    callMin, callMax, callCurrent,
                    systemMin, systemMax, systemCurrent,
                    mode
                )
                result.success(null)
            }
            "setBTStatus" -> {
                val isOpen = call.argument<Boolean>("isOpen") ?: false
                if (isOpen) {
                    LargeDataHandler.getInstance().openBT()
                }
                result.success(null)
            }
            "getBTStatus" -> {
                try {
                    val btAdapter = BluetoothAdapter.getDefaultAdapter()
                    val btState = if (btAdapter != null && btAdapter.isEnabled) 5 else 4
                    mainHandler.post {
                        eventSink?.success(mapOf(
                            "type" to "bluetoothState",
                            "state" to btState
                        ))
                    }
                } catch (e: Exception) {
                    // ignore
                }
                result.success(null)
            }
            "stopAIChat" -> {
                result.success(null)
            }
            "convertOpusToPcm" -> {
                val inputPath = call.argument<String>("inputPath")
                val outputPath = call.argument<String>("outputPath")
                if (inputPath == null || outputPath == null) {
                    result.success(false)
                    return
                }
                Thread {
                    val success = decodeOpusToPcm(inputPath, outputPath)
                    mainHandler.post {
                        result.success(success)
                    }
                }.start()
            }
            "startToDownloadMediaResource" -> {
                val storagePath = File(context?.getExternalFilesDir(""), "DCIM_1").absolutePath
                val dir = File(storagePath)
                if (!dir.exists()) {
                    dir.mkdirs()
                }

                var currentBatchIndex = 0
                var totalBatchFiles = 0

                val control = GlassesControl.getInstance(application!!)
                if (control != null) {
                    control.initGlasses(storagePath)
                    control.setWifiDownloadListener(object : GlassesControl.WifiFilesDownloadListener {
                        override fun eisEnd(fileName: String, filePath: String) {}

                        override fun eisError(fileName: String, sourcePath: String, errorInfo: String) {}

                        override fun fileCount(index: Int, total: Int) {
                            currentBatchIndex = index
                            totalBatchFiles = total
                            mainHandler.post {
                                eventSink?.success(mapOf(
                                    "type" to "downloadProgress",
                                    "receivedSize" to index,
                                    "expectedSize" to total,
                                    "index" to index,
                                    "count" to total,
                                    "progress" to (index.toDouble() / total.toDouble())
                                ))
                            }
                        }

                        override fun fileDownloadComplete() {
                            mainHandler.post {
                                eventSink?.success(mapOf(
                                    "type" to "downloadComplete",
                                    "filePath" to "",
                                    "error" to "",
                                    "index" to totalBatchFiles,
                                    "count" to totalBatchFiles
                                ))
                            }
                        }

                        override fun fileDownloadError(fileType: Int, errorType: Int) {
                            mainHandler.post {
                                eventSink?.success(mapOf(
                                    "type" to "downloadComplete",
                                    "filePath" to "",
                                    "error" to "Download error (type $errorType)",
                                    "index" to currentBatchIndex,
                                    "count" to totalBatchFiles
                                ))
                            }
                        }

                        override fun fileProgress(fileName: String, progress: Int) {
                            mainHandler.post {
                                eventSink?.success(mapOf(
                                    "type" to "downloadProgress",
                                    "receivedSize" to progress,
                                    "expectedSize" to 100,
                                    "progress" to (progress.toDouble() / 100.0).coerceIn(0.0, 1.0)
                                ))
                            }
                        }

                        override fun fileWasDownloadSuccessfully(entity: GlassAlbumEntity) {
                            mainHandler.post {
                                eventSink?.success(mapOf(
                                    "type" to "downloadComplete",
                                    "filePath" to (entity.filePath ?: ""),
                                    "error" to "",
                                    "index" to currentBatchIndex,
                                    "count" to totalBatchFiles
                                ))
                            }
                        }

                        override fun onGlassesControlSuccess() {}

                        override fun onGlassesFail(errorCode: Int) {
                            mainHandler.post {
                                eventSink?.success(mapOf(
                                    "type" to "downloadComplete",
                                    "filePath" to "",
                                    "error" to "Glasses control fail (error $errorCode)",
                                    "index" to 0,
                                    "count" to 0
                                ))
                            }
                        }

                        override fun recordingToPcm(fileName: String, filePath: String, duration: Int) {}

                        override fun recordingToPcmError(fileName: String, errorInfo: String) {}

                        override fun wifiSpeed(wifiSpeed: String) {}
                    })
                    control.importAlbum()
                    result.success(null)
                } else {
                    result.error("ERROR", "GlassesControl instance is null", null)
                }
            }
            else -> {
                result.notImplemented()
            }
        }
    }

    inner class PluginBleReceiver : QCBluetoothCallbackCloneReceiver() {
        override fun connectStatue(device: BluetoothDevice?, connected: Boolean) {
            if (device != null && connected) {
                val devName = device.name ?: DeviceManager.getInstance().deviceName ?: "Smart Specs"
                val devAddress = device.address ?: DeviceManager.getInstance().deviceAddress ?: ""
                DeviceManager.getInstance().deviceName = devName
                DeviceManager.getInstance().deviceAddress = devAddress

                val wifiMac = devAddress.replace(":", "")
                var wifiName = if (devName.contains("_")) devName.split("_")[0] else devName
                if (wifiName.length > 20) {
                    wifiName = wifiName.substring(0, 20)
                }
                DeviceManager.getInstance().wifiName = "${wifiName}_$wifiMac"
                DeviceManager.getInstance().wifiPassword = "123456789"
                Log.i(TAG, "👓 [BLE CONNECTED] devName=$devName, devAddress=$devAddress, wifiName=${wifiName}_$wifiMac")

                mainHandler.post {
                    eventSink?.success(mapOf(
                        "type" to "deviceState",
                        "state" to 2 // connecting (GATT connected, discovery pending)
                    ))
                }
            } else {
                Log.i(TAG, "👓 [BLE DISCONNECTED] Device disconnected via connectStatue")
                BleOperateManager.getInstance().setNeedConnect(false)
                BleOperateManager.getInstance().isReady = false
                mainHandler.removeCallbacksAndMessages(null)
                mainHandler.post {
                    eventSink?.success(mapOf(
                        "type" to "deviceState",
                        "state" to 5 // disconnected
                    ))
                }
            }
        }

        override fun onServiceDiscovered() {
            val isConnected = try {
                BleOperateManager.getInstance().isConnected
            } catch (e: Exception) {
                false
            }
            if (!isConnected) {
                Log.w(TAG, "👓 [BLE] onServiceDiscovered called but BleOperateManager.isConnected is false. Ignoring stale discovery broadcast.")
                return
            }

            LargeDataHandler.getInstance().initEnable()
            BleOperateManager.getInstance().isReady = true
            mainHandler.post {
                eventSink?.success(mapOf(
                    "type" to "deviceState",
                    "state" to 3 // connected (fully initialized)
                ))
            }
        }

        override fun bleStatus(status: Int, newState: Int) {
            super.bleStatus(status, newState)
            if (newState == BluetoothProfile.STATE_DISCONNECTED || (status != BluetoothGatt.GATT_SUCCESS && !BleOperateManager.getInstance().isConnected)) {
                Log.i(TAG, "👓 [BLE STATUS] Disconnect status: status=$status, newState=$newState")
                BleOperateManager.getInstance().setNeedConnect(false)
                BleOperateManager.getInstance().isReady = false
                mainHandler.removeCallbacksAndMessages(null)
                mainHandler.post {
                    eventSink?.success(mapOf(
                        "type" to "deviceState",
                        "state" to 5 // disconnected
                    ))
                }
            }
        }

        override fun onCharacteristicChange(address: String?, uuid: String?, data: ByteArray?) {}

        override fun onCharacteristicRead(uuid: String?, data: ByteArray?) {
            if (uuid != null && data != null) {
                val version = String(data, Charsets.UTF_8)
                if (uuid == Constants.CHAR_FIRMWARE_REVISION.toString()) {
                    firmwareVersion = version
                } else if (uuid == Constants.CHAR_HW_REVISION.toString()) {
                    hardwareVersion = version
                }
            }
        }
    }

    private val deviceNotifyListener = object : GlassesDeviceNotifyListener() {
        override fun parseData(cmdType: Int, response: GlassesDeviceNotifyRsp?) {
            if (response == null || response.loadData == null) return
            val data = response.loadData
            if (data.size <= 6) return
            when (data[6].toInt()) {
                // Battery level report
                0x05 -> {
                    if (data.size > 8) {
                        val battery = data[7].toInt()
                        val charging = data[8].toInt() == 1
                        mainHandler.post {
                            eventSink?.success(mapOf(
                                "type" to "batteryLevel",
                                "battery" to battery,
                                "charging" to charging
                            ))
                        }
                    }
                }
                // AI Quick recognition trigger
                0x02 -> {
                    LargeDataHandler.getInstance().getPictureThumbnails { _, success, thumbnailBytes ->
                        if (success && thumbnailBytes != null) {
                            mainHandler.post {
                                eventSink?.success(mapOf(
                                    "type" to "aiChatImage",
                                    "data" to thumbnailBytes
                                ))
                            }
                        }
                    }
                }
                // Mic started speaking (Audio trigger)
                0x03 -> {
                    // Handled inside AI Voice session triggers
                }
                // OTA upgrade
                0x04 -> {
                    if (data.size > 9) {
                        val download = data[7].toInt()
                        val soc = data[8].toInt()
                        val nor = data[9].toInt()
                        mainHandler.post {
                            eventSink?.success(mapOf(
                                "type" to "wifiUpgradeProgress",
                                "download" to download,
                                "upgrade1" to soc,
                                "upgrade2" to nor
                            ))
                        }
                    }
                }
            }
        }
    }

    private fun checkSpecsSignature(scanRecord: ByteArray?): Boolean {
        if (scanRecord == null || scanRecord.isEmpty()) return false
        var i = 0
        while (i < scanRecord.size) {
            val length = scanRecord[i].toInt() and 0xFF
            if (length == 0 || i + length >= scanRecord.size) break
            val type = scanRecord[i + 1].toInt() and 0xFF

            // AD Type 0x16 = Service Data (16-bit UUID)
            // Specs firmware uses 0x3802 (0x02, 0x38 in little-endian)
            if (type == 0x16 && length >= 3) {
                val uuidLo = scanRecord[i + 2].toInt() and 0xFF
                val uuidHi = scanRecord[i + 3].toInt() and 0xFF
                if (uuidLo == 0x02 && uuidHi == 0x38) {
                    return true
                }
            }

            // AD Type 0xFF = Manufacturer Specific Data
            // Specs firmware uses Company ID 0x1234 (0x34, 0x12 in little-endian)
            if (type == 0xFF && length >= 3) {
                val compLo = scanRecord[i + 2].toInt() and 0xFF
                val compHi = scanRecord[i + 3].toInt() and 0xFF
                if (compLo == 0x34 && compHi == 0x12) {
                    return true
                }
            }

            i += length + 1
        }
        return false
    }

    private fun extractLocalName(scanRecord: ByteArray?): String? {
        if (scanRecord == null || scanRecord.isEmpty()) return null
        var i = 0
        while (i < scanRecord.size) {
            val length = scanRecord[i].toInt() and 0xFF
            if (length == 0 || i + length >= scanRecord.size) break
            val type = scanRecord[i + 1].toInt() and 0xFF
            // AD Type 0x08 (Shortened Local Name) or 0x09 (Complete Local Name)
            if ((type == 0x08 || type == 0x09) && length > 1) {
                return try {
                    String(scanRecord, i + 2, length - 1, Charsets.UTF_8).trim()
                } catch (e: Exception) {
                    null
                }
            }
            i += length + 1
        }
        return null
    }

    private fun decodeOpusToPcm(inputPath: String, outputPath: String): Boolean {
        val inputFile = File(inputPath)
        if (!inputFile.exists() || inputFile.length() == 0L) {
            Log.e(TAG, "Input opus file does not exist or is empty: $inputPath")
            return false
        }

        val outputFile = File(outputPath)
        outputFile.parentFile?.mkdirs()
        if (outputFile.exists()) {
            outputFile.delete()
        }

        var codec: MediaCodec? = null
        var fis: FileInputStream? = null
        var fos: FileOutputStream? = null

        try {
            val sampleRate = 16000
            val channels = 1
            val format = MediaFormat.createAudioFormat("audio/opus", sampleRate, channels)

            // CSD-0: 19-byte OpusHead structure (RFC 7845)
            val csd0 = ByteBuffer.allocate(19).order(ByteOrder.LITTLE_ENDIAN).apply {
                put("OpusHead".toByteArray(Charsets.US_ASCII)) // 8 bytes magic
                put(1.toByte()) // Version = 1
                put(channels.toByte()) // Channel count = 1
                putShort(0.toShort()) // Pre-skip = 0
                putInt(sampleRate) // Input sample rate = 16000
                putShort(0.toShort()) // Output gain = 0
                put(0.toByte()) // Channel mapping family = 0
            }.array()

            // CSD-1: Codec delay in nanoseconds (8 bytes)
            val csd1 = ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN).putLong(0L).array()

            // CSD-2: Seek preroll in nanoseconds (8 bytes, 80ms standard)
            val csd2 = ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN).putLong(80000000L).array()

            format.setByteBuffer("csd-0", ByteBuffer.wrap(csd0))
            format.setByteBuffer("csd-1", ByteBuffer.wrap(csd1))
            format.setByteBuffer("csd-2", ByteBuffer.wrap(csd2))

            codec = MediaCodec.createDecoderByType("audio/opus")
            codec.configure(format, null, null, 0)
            codec.start()

            fis = FileInputStream(inputFile)
            fos = FileOutputStream(outputFile)

            val isWav = outputPath.endsWith(".wav", ignoreCase = true)
            if (isWav) {
                // Reserve 44 bytes for standard WAV header
                fos.write(ByteArray(44))
            }

            val bufferInfo = MediaCodec.BufferInfo()
            val packetSize = 40
            val packet = ByteArray(packetSize)
            var sawInputEOS = false
            var sawOutputEOS = false
            var presentationTimeUs = 0L
            val frameDurationUs = 20000L // 20ms per packet
            val timeoutUs = 10000L
            var totalPcmBytes = 0L

            while (!sawOutputEOS) {
                if (!sawInputEOS) {
                    val inputBufferId = codec.dequeueInputBuffer(timeoutUs)
                    if (inputBufferId >= 0) {
                        val inputBuffer = codec.getInputBuffer(inputBufferId)
                        if (inputBuffer != null) {
                            inputBuffer.clear()
                            val bytesRead = fis.read(packet)
                            if (bytesRead <= 0) {
                                sawInputEOS = true
                                codec.queueInputBuffer(inputBufferId, 0, 0, presentationTimeUs, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            } else {
                                inputBuffer.put(packet, 0, bytesRead)
                                codec.queueInputBuffer(inputBufferId, 0, bytesRead, presentationTimeUs, 0)
                                presentationTimeUs += frameDurationUs
                            }
                        }
                    }
                }

                val outputBufferId = codec.dequeueOutputBuffer(bufferInfo, timeoutUs)
                if (outputBufferId >= 0) {
                    if ((bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                        sawOutputEOS = true
                    }
                    if (bufferInfo.size > 0) {
                        val outputBuffer = codec.getOutputBuffer(outputBufferId)
                        if (outputBuffer != null) {
                            outputBuffer.position(bufferInfo.offset)
                            outputBuffer.limit(bufferInfo.offset + bufferInfo.size)
                            val chunk = ByteArray(bufferInfo.size)
                            outputBuffer.get(chunk)
                            fos.write(chunk)
                            totalPcmBytes += bufferInfo.size
                        }
                    }
                    codec.releaseOutputBuffer(outputBufferId, false)
                } else if (outputBufferId == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    Log.d(TAG, "Opus decoder output format: ${codec.outputFormat}")
                }
            }

            fos.flush()

            if (isWav && totalPcmBytes > 0) {
                writeWavHeader(outputFile, totalPcmBytes, sampleRate, channels)
            }

            val finalLength = outputFile.length()
            Log.i(TAG, "✅ [Opus->PCM] Decoded ${inputFile.name} to $outputPath ($finalLength bytes)")
            return finalLength > 0
        } catch (e: Exception) {
            Log.e(TAG, "❌ [Opus->PCM] Failed decoding $inputPath: ${e.message}", e)
            return false
        } finally {
            try { codec?.stop() } catch (_: Exception) {}
            try { codec?.release() } catch (_: Exception) {}
            try { fis?.close() } catch (_: Exception) {}
            try { fos?.close() } catch (_: Exception) {}
        }
    }

    private fun writeWavHeader(file: File, pcmDataLength: Long, sampleRate: Int, channels: Int) {
        try {
            val totalDataLen = pcmDataLength + 36
            val byteRate = sampleRate * channels * 2
            val header = ByteArray(44)
            val buf = ByteBuffer.wrap(header).order(ByteOrder.LITTLE_ENDIAN)

            buf.put("RIFF".toByteArray(Charsets.US_ASCII))
            buf.putInt(totalDataLen.toInt())
            buf.put("WAVE".toByteArray(Charsets.US_ASCII))
            buf.put("fmt ".toByteArray(Charsets.US_ASCII))
            buf.putInt(16) // Subchunk1Size (16 for PCM)
            buf.putShort(1.toShort()) // AudioFormat (1 for PCM)
            buf.putShort(channels.toShort())
            buf.putInt(sampleRate)
            buf.putInt(byteRate)
            buf.putShort((channels * 2).toShort()) // BlockAlign
            buf.putShort(16.toShort()) // BitsPerSample
            buf.put("data".toByteArray(Charsets.US_ASCII))
            buf.putInt(pcmDataLength.toInt())

            java.io.RandomAccessFile(file, "rw").use { raf ->
                raf.seek(0)
                raf.write(header)
            }
        } catch (e: Exception) {
            Log.w(TAG, "Failed writing WAV header: ${e.message}")
        }
    }
}
