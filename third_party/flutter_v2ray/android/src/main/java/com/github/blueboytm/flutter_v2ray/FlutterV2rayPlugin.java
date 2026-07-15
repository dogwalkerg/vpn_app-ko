package com.github.blueboytm.flutter_v2ray;

import android.Manifest;
import android.annotation.SuppressLint;
import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.pm.PackageManager;
import android.net.VpnService;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.core.app.ActivityCompat;

import com.github.blueboytm.flutter_v2ray.v2ray.V2rayController;
import com.github.blueboytm.flutter_v2ray.v2ray.V2rayReceiver;
import com.github.blueboytm.flutter_v2ray.v2ray.utils.AppConfigs;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.embedding.engine.plugins.activity.ActivityAware;
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding;
import io.flutter.plugin.common.EventChannel;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.PluginRegistry;

public class FlutterV2rayPlugin implements FlutterPlugin, ActivityAware, PluginRegistry.ActivityResultListener {
    private static final int REQUEST_CODE_VPN_PERMISSION = 24;
    private static final int REQUEST_CODE_POST_NOTIFICATIONS = 1;
    private static final long STATUS_QUERY_TIMEOUT_MS = 3000L;

    private final ExecutorService executor = Executors.newSingleThreadExecutor();
    private final Handler mainHandler = new Handler(Looper.getMainLooper());
    private final Map<String, MethodChannel.Result> pendingStatusResults = new ConcurrentHashMap<>();
    private final Map<String, MethodChannel.Result> pendingDelayResults = new ConcurrentHashMap<>();
    private MethodChannel vpnControlMethod;
    private EventChannel vpnStatusEvent;
    private EventChannel.EventSink vpnStatusSink;
    private Context applicationContext;
    private Activity activity;
    private ActivityPluginBinding activityBinding;
    private V2rayReceiver statusReceiver;
    private boolean statusReceiverRegistered;
    private long latestStatusGeneration;
    private MethodChannel.Result pendingPermissionResult;

    @SuppressLint("DiscouragedApi")
    @Override
    public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
        applicationContext = binding.getApplicationContext();
        vpnControlMethod = new MethodChannel(binding.getBinaryMessenger(), "flutter_v2ray");
        vpnStatusEvent = new EventChannel(binding.getBinaryMessenger(), "flutter_v2ray/status");
        registerStatusReceiver();

        vpnStatusEvent.setStreamHandler(new EventChannel.StreamHandler() {
            @Override
            public void onListen(Object arguments, EventChannel.EventSink events) {
                vpnStatusSink = events;
            }

            @Override
            public void onCancel(Object arguments) {
                vpnStatusSink = null;
            }
        });

        vpnControlMethod.setMethodCallHandler((call, result) -> {
            switch (call.method) {
                case "startV2Ray":
                    AppConfigs.NOTIFICATION_DISCONNECT_BUTTON_NAME = call.argument("notificationDisconnectButtonName");
                    if (Boolean.TRUE.equals(call.argument("proxy_only"))) {
                        V2rayController.changeConnectionMode(AppConfigs.V2RAY_CONNECTION_MODES.PROXY_ONLY);
                    }
                    V2rayController.StartV2ray(applicationContext, call.argument("remark"), call.argument("config"), call.argument("blocked_apps"), call.argument("bypass_subnets"));
                    result.success(null);
                    break;
                case "stopV2Ray":
                    V2rayController.StopV2ray(applicationContext);
                    result.success(null);
                    break;
                case "initializeV2Ray":
                    String iconResourceName = call.argument("notificationIconResourceName");
                    String iconResourceType = call.argument("notificationIconResourceType");
                    V2rayController.init(applicationContext, applicationContext.getResources().getIdentifier(iconResourceName, iconResourceType, applicationContext.getPackageName()), "Osca");
                    result.success(null);
                    break;
                case "getV2RayStatus":
                    requestCurrentStatus(result);
                    break;
                case "getServerDelay":
                    executor.submit(() -> {
                        try {
                            result.success(V2rayController.getV2rayServerDelay(call.argument("config"), call.argument("url")));
                        } catch (Exception e) {
                            result.success(-1);
                        }
                    });
                    break;
                case "getConnectedServerDelay":
                    requestConnectedServerDelay(call.argument("url"), result);
                    break;
                case "getCoreVersion":
                    result.success(V2rayController.getCoreVersion());
                    break;
                case "requestPermission":
                    requestVpnPermission(result);
                    break;
                default:
                    result.notImplemented();
                    break;
            }
        });
    }

    private void registerStatusReceiver() {
        if (statusReceiverRegistered || applicationContext == null) return;
        statusReceiver = new V2rayReceiver(new V2rayReceiver.Listener() {
            @Override
            public void onStatus(ArrayList<String> status, String queryId) {
                handleStatus(status, queryId);
            }

            @Override
            public void onDelay(long delay, String queryId) {
                MethodChannel.Result pending = pendingDelayResults.remove(queryId);
                if (pending != null) pending.success(delay);
            }
        });
        IntentFilter filter = new IntentFilter(AppConfigs.CONNECTION_INFO_ACTION);
        filter.addAction(AppConfigs.CONNECTED_SERVER_DELAY_ACTION);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            applicationContext.registerReceiver(statusReceiver, filter, Context.RECEIVER_NOT_EXPORTED);
        } else {
            applicationContext.registerReceiver(statusReceiver, filter);
        }
        statusReceiverRegistered = true;
    }

    private void unregisterStatusReceiver() {
        if (!statusReceiverRegistered || applicationContext == null || statusReceiver == null) return;
        try {
            applicationContext.unregisterReceiver(statusReceiver);
        } catch (IllegalArgumentException ignored) {
        }
        statusReceiverRegistered = false;
        statusReceiver = null;
    }

    private void handleStatus(ArrayList<String> status, String queryId) {
        long generation = status.size() > 8 ? parseLong(status.get(8)) : 0L;
        if (queryId != null && !queryId.isEmpty()) {
            if (generation > latestStatusGeneration) latestStatusGeneration = generation;
            MethodChannel.Result pending = pendingStatusResults.remove(queryId);
            if (pending != null) pending.success(statusToMap(status));
            return;
        }
        if (generation > 0L && generation < latestStatusGeneration) return;
        if (generation > latestStatusGeneration) latestStatusGeneration = generation;
        EventChannel.EventSink sink = vpnStatusSink;
        if (sink != null) sink.success(status);
    }

    private Map<String, Object> statusToMap(ArrayList<String> status) {
        Map<String, Object> result = new HashMap<>();
        result.put("duration", status.size() > 0 ? status.get(0) : "00:00:00");
        result.put("uploadSpeed", status.size() > 1 ? status.get(1) : "0");
        result.put("downloadSpeed", status.size() > 2 ? status.get(2) : "0");
        result.put("upload", status.size() > 3 ? status.get(3) : "0");
        result.put("download", status.size() > 4 ? status.get(4) : "0");
        result.put("state", status.size() > 5 ? status.get(5) : "DISCONNECTED");
        result.put("error", status.size() > 6 ? status.get(6) : "");
        result.put("sessionId", status.size() > 7 ? status.get(7) : "");
        result.put("generation", status.size() > 8 ? status.get(8) : "0");
        return result;
    }

    private long parseLong(String value) {
        try {
            return Long.parseLong(value);
        } catch (NumberFormatException ignored) {
            return 0L;
        }
    }

    private void requestCurrentStatus(MethodChannel.Result result) {
        final String queryId = UUID.randomUUID().toString();
        pendingStatusResults.put(queryId, result);
        mainHandler.postDelayed(() -> {
            MethodChannel.Result pending = pendingStatusResults.remove(queryId);
            if (pending != null) pending.error("STATUS_QUERY_TIMEOUT", "Native VPN service status query timed out", null);
        }, STATUS_QUERY_TIMEOUT_MS);
        try {
            V2rayController.RequestConnectionStatus(applicationContext, queryId);
        } catch (Exception e) {
            MethodChannel.Result pending = pendingStatusResults.remove(queryId);
            if (pending != null) pending.error("STATUS_QUERY_FAILED", e.getMessage() == null ? "Native VPN service status query failed" : e.getMessage(), null);
        }
    }

    private void requestConnectedServerDelay(String url, MethodChannel.Result result) {
        final String queryId = UUID.randomUUID().toString();
        pendingDelayResults.put(queryId, result);
        mainHandler.postDelayed(() -> {
            MethodChannel.Result pending = pendingDelayResults.remove(queryId);
            if (pending != null) pending.success(-1L);
        }, STATUS_QUERY_TIMEOUT_MS);
        try {
            V2rayController.RequestConnectedServerDelay(applicationContext, url, queryId);
        } catch (Exception e) {
            MethodChannel.Result pending = pendingDelayResults.remove(queryId);
            if (pending != null) pending.success(-1L);
        }
    }

    private void requestVpnPermission(MethodChannel.Result result) {
        if (activity == null) {
            result.error("NO_ACTIVITY", "VPN permission requires a foreground activity", null);
            return;
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                ActivityCompat.checkSelfPermission(activity, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            ActivityCompat.requestPermissions(activity, new String[]{Manifest.permission.POST_NOTIFICATIONS}, REQUEST_CODE_POST_NOTIFICATIONS);
        }
        final Intent request = VpnService.prepare(activity);
        if (request == null) {
            result.success(true);
            return;
        }
        if (pendingPermissionResult != null) {
            result.error("PERMISSION_PENDING", "A VPN permission request is already active", null);
            return;
        }
        pendingPermissionResult = result;
        activity.startActivityForResult(request, REQUEST_CODE_VPN_PERMISSION);
    }

    @Override
    public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
        unregisterStatusReceiver();
        vpnStatusSink = null;
        for (MethodChannel.Result pending : pendingStatusResults.values()) {
            pending.error("ENGINE_DETACHED", "Flutter engine detached", null);
        }
        pendingStatusResults.clear();
        for (MethodChannel.Result pending : pendingDelayResults.values()) {
            pending.success(-1L);
        }
        pendingDelayResults.clear();
        vpnControlMethod.setMethodCallHandler(null);
        vpnStatusEvent.setStreamHandler(null);
        executor.shutdown();
        applicationContext = null;
    }

    @Override
    public void onAttachedToActivity(@NonNull ActivityPluginBinding binding) {
        activityBinding = binding;
        activity = binding.getActivity();
        binding.addActivityResultListener(this);
    }

    @Override
    public void onDetachedFromActivityForConfigChanges() {
        detachFromActivity();
    }

    @Override
    public void onReattachedToActivityForConfigChanges(@NonNull ActivityPluginBinding binding) {
        onAttachedToActivity(binding);
    }

    @Override
    public void onDetachedFromActivity() {
        detachFromActivity();
    }

    private void detachFromActivity() {
        if (activityBinding != null) activityBinding.removeActivityResultListener(this);
        activityBinding = null;
        activity = null;
    }

    @Override
    public boolean onActivityResult(int requestCode, int resultCode, @Nullable Intent data) {
        if (requestCode != REQUEST_CODE_VPN_PERMISSION) return false;
        MethodChannel.Result result = pendingPermissionResult;
        pendingPermissionResult = null;
        if (result != null) result.success(resultCode == Activity.RESULT_OK);
        return true;
    }
}
