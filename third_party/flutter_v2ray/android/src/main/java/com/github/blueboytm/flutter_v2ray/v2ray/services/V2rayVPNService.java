package com.github.blueboytm.flutter_v2ray.v2ray.services;

import android.app.Service;
import android.content.Intent;
import android.net.ProxyInfo;
import android.net.VpnService;
import android.os.Build;
import android.os.ParcelFileDescriptor;
import android.util.Log;

import com.github.blueboytm.flutter_v2ray.v2ray.core.V2rayCoreManager;
import com.github.blueboytm.flutter_v2ray.v2ray.interfaces.V2rayServicesListener;
import com.github.blueboytm.flutter_v2ray.v2ray.utils.AppConfigs;
import com.github.blueboytm.flutter_v2ray.v2ray.utils.V2rayConfig;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.io.File;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;

import hev.htproxy.TProxyService;

public class V2rayVPNService extends VpnService implements V2rayServicesListener {
    private static final String TAG = "V2rayVPNService";
    private static final int TUN_MTU = 1500;

    private final TProxyService tun2socks = new TProxyService();
    private ParcelFileDescriptor vpnInterface;
    private V2rayConfig v2rayConfig;
    private volatile boolean tunnelRunning;
    private volatile boolean stopping;

    @Override
    public void onCreate() {
        super.onCreate();
        V2rayCoreManager.getInstance().setUpListener(this);
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent == null) return START_NOT_STICKY;
        AppConfigs.V2RAY_SERVICE_COMMANDS command =
                (AppConfigs.V2RAY_SERVICE_COMMANDS) intent.getSerializableExtra("COMMAND");
        if (command == null) return START_NOT_STICKY;

        if (command == AppConfigs.V2RAY_SERVICE_COMMANDS.START_SERVICE) {
            v2rayConfig = (V2rayConfig) intent.getSerializableExtra("V2RAY_CONFIG");
            if (v2rayConfig == null) {
                stopSelf();
                return START_NOT_STICKY;
            }
            restartRunningCoreIfNeeded();
            stopping = false;
            V2rayCoreManager.getInstance().showNotification(v2rayConfig);
            if (!V2rayCoreManager.getInstance().startCore(v2rayConfig)) {
                V2rayCoreManager.getInstance().markTunnelFailed("Xray core failed to start");
                stopAllProcesses();
            }
        } else if (command == AppConfigs.V2RAY_SERVICE_COMMANDS.STOP_SERVICE) {
            stopAllProcesses();
            AppConfigs.V2RAY_CONFIG = null;
        } else if (command == AppConfigs.V2RAY_SERVICE_COMMANDS.MEASURE_DELAY) {
            new Thread(() -> {
                Intent response = new Intent(AppConfigs.CONNECTED_SERVER_DELAY_ACTION);
                response.setPackage(getPackageName());
                AppConfigs.DELAY_URL = intent.getStringExtra("URL");
                response.putExtra("DELAY", V2rayCoreManager.getInstance().getConnectedV2rayServerDelay());
                response.putExtra("QUERY_ID", intent.getStringExtra("QUERY_ID"));
                sendBroadcast(response);
            }, "MeasureConnectedV2rayDelay").start();
        } else if (command == AppConfigs.V2RAY_SERVICE_COMMANDS.QUERY_STATUS) {
            V2rayCoreManager.getInstance().broadcastConnectionInfo(
                    intent.getStringExtra("QUERY_ID"));
            if (!V2rayCoreManager.getInstance().isV2rayCoreRunning()) stopSelf();
        }
        return V2rayCoreManager.getInstance().isV2rayCoreRunning()
                ? START_STICKY
                : START_NOT_STICKY;
    }

    private synchronized void stopAllProcesses() {
        if (stopping) return;
        stopping = true;
        try {
            stopTunnelBridge();
            V2rayCoreManager.getInstance().stopCore();
        } finally {
            closeVpnInterface();
            stopForeground(true);
            stopSelf();
        }
    }

    private synchronized void restartRunningCoreIfNeeded() {
        if (!V2rayCoreManager.getInstance().isV2rayCoreRunning() &&
                !tunnelRunning) {
            return;
        }
        stopping = true;
        stopTunnelBridge();
        V2rayCoreManager.getInstance().stopCore();
        closeVpnInterface();
        V2rayCoreManager.getInstance().setUpListener(this);
        stopping = false;
    }

    private void stopTunnelBridge() {
        tunnelRunning = false;
        try {
            tun2socks.TProxyStopService();
        } catch (Exception e) {
            Log.w(TAG, "Unable to stop HEV tun2socks", e);
        }
    }

    private void setupTunnel() {
        if (prepare(this) != null) {
            V2rayCoreManager.getInstance().markTunnelFailed(
                    "VpnService permission is not prepared");
            stopAllProcesses();
            return;
        }

        Builder builder = new Builder()
                .setSession(v2rayConfig.REMARK)
                .setMtu(TUN_MTU)
                .addAddress("10.0.0.1", 30)
                .addAddress("fd00:198:18::1", 64);

        if (v2rayConfig.BYPASS_SUBNETS == null || v2rayConfig.BYPASS_SUBNETS.isEmpty()) {
            builder.addRoute("0.0.0.0", 0);
            builder.addRoute("::", 0);
        } else {
            for (String subnet : v2rayConfig.BYPASS_SUBNETS) {
                String[] parts = subnet.split("/");
                if (parts.length != 2) continue;
                try {
                    builder.addRoute(parts[0], Integer.parseInt(parts[1]));
                } catch (IllegalArgumentException ignored) {
                }
            }
        }

        if (v2rayConfig.BLOCKED_APPS != null) {
            for (String packageName : v2rayConfig.BLOCKED_APPS) {
                try {
                    builder.addDisallowedApplication(packageName);
                } catch (Exception ignored) {
                }
            }
        }

        addDnsServers(builder);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            builder.setMetered(false);
            builder.setHttpProxy(ProxyInfo.buildDirectProxy(
                    "127.0.0.1", v2rayConfig.LOCAL_HTTP_PORT));
        }

        closeVpnInterface();
        try {
            vpnInterface = builder.establish();
            if (vpnInterface == null) {
                throw new IllegalStateException("VpnService.Builder.establish returned null");
            }
            startTun2socks(vpnInterface.getFd());
            tunnelRunning = true;
            V2rayCoreManager.getInstance().markTunnelReady();
        } catch (Exception e) {
            Log.e(TAG, "Unable to establish Android packet tunnel", e);
            V2rayCoreManager.getInstance().markTunnelFailed(
                    "TUN establish failed: " + safeMessage(e));
            stopAllProcesses();
        }
    }

    private void addDnsServers(Builder builder) {
        try {
            JSONObject json = new JSONObject(v2rayConfig.V2RAY_FULL_JSON_CONFIG);
            JSONArray servers = json.getJSONObject("dns").getJSONArray("servers");
            for (int i = 0; i < servers.length(); i++) {
                Object item = servers.get(i);
                if (item instanceof String) {
                    String server = (String) item;
                    if (!server.contains("://")) builder.addDnsServer(server);
                }
            }
        } catch (JSONException | IllegalArgumentException e) {
            Log.w(TAG, "Unable to apply DNS servers from Xray config", e);
        }
    }

    private void startTun2socks(int tunFd) throws Exception {
        JSONObject config = new JSONObject();
        config.put("tunnel", new JSONObject().put("mtu", TUN_MTU));
        config.put("socks5", new JSONObject()
                .put("port", v2rayConfig.LOCAL_SOCKS5_PORT)
                .put("address", "127.0.0.1")
                .put("udp", "udp"));
        config.put("misc", new JSONObject()
                .put("task-stack-size", 24576)
                .put("connect-timeout", 5000)
                .put("tcp-read-write-timeout", 300000)
                .put("udp-read-write-timeout", 60000)
                .put("limit-nofile", 65535)
                .put("log-level", "error"));

        File configFile = new File(getFilesDir(), "hev-socks5-tunnel.json");
        try (FileOutputStream output = new FileOutputStream(configFile, false)) {
            output.write(config.toString().getBytes(StandardCharsets.UTF_8));
            output.flush();
        }
        tun2socks.TProxyStartService(configFile.getAbsolutePath(), tunFd);
    }

    private void closeVpnInterface() {
        ParcelFileDescriptor current = vpnInterface;
        vpnInterface = null;
        if (current == null) return;
        try {
            current.close();
        } catch (Exception ignored) {
        }
    }

    private static String safeMessage(Exception e) {
        return e.getMessage() == null ? e.getClass().getSimpleName() : e.getMessage();
    }

    @Override
    public void onDestroy() {
        if (!stopping) stopAllProcesses();
        super.onDestroy();
    }

    @Override
    public void onRevoke() {
        stopAllProcesses();
    }

    @Override
    public boolean onProtect(int socket) {
        return protect(socket);
    }

    @Override
    public Service getService() {
        return this;
    }

    @Override
    public void startService() {
        setupTunnel();
    }

    @Override
    public void stopService() {
        stopAllProcesses();
    }
}
