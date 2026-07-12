package com.github.blueboytm.flutter_v2ray.v2ray.services;

import android.app.Service;
import android.content.Intent;
import android.net.LocalSocket;
import android.net.LocalSocketAddress;
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
import java.io.FileDescriptor;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.ArrayList;
import java.util.Arrays;

public class V2rayVPNService extends VpnService implements V2rayServicesListener {
    private ParcelFileDescriptor mInterface;
    private Process process;
    private V2rayConfig v2rayConfig;
    private boolean isRunning = true;
    private volatile boolean stopping = false;

    @Override
    public void onCreate() {
        super.onCreate();
        V2rayCoreManager.getInstance().setUpListener(this);
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent == null) return START_NOT_STICKY;
        AppConfigs.V2RAY_SERVICE_COMMANDS startCommand = (AppConfigs.V2RAY_SERVICE_COMMANDS) intent.getSerializableExtra("COMMAND");
        if (startCommand == null) return START_NOT_STICKY;
        if (startCommand.equals(AppConfigs.V2RAY_SERVICE_COMMANDS.START_SERVICE)) {
            stopping = false;
            v2rayConfig = (V2rayConfig) intent.getSerializableExtra("V2RAY_CONFIG");
            if (v2rayConfig == null) {
                stopSelf();
                return START_NOT_STICKY;
            }
            V2rayCoreManager.getInstance().showNotification(v2rayConfig);
            if (V2rayCoreManager.getInstance().isV2rayCoreRunning()) {
                V2rayCoreManager.getInstance().stopCore();
            }
            if (V2rayCoreManager.getInstance().startCore(v2rayConfig)) {
                Log.e(V2rayProxyOnlyService.class.getSimpleName(), "onStartCommand success => v2ray core started.");
            } else {
                this.onDestroy();
            }
        } else if (startCommand.equals(AppConfigs.V2RAY_SERVICE_COMMANDS.STOP_SERVICE)) {
            V2rayCoreManager.getInstance().stopCore();
            AppConfigs.V2RAY_CONFIG = null;
        } else if (startCommand.equals(AppConfigs.V2RAY_SERVICE_COMMANDS.MEASURE_DELAY)) {
            new Thread(() -> {
                Intent sendB = new Intent("CONNECTED_V2RAY_SERVER_DELAY");
                sendB.putExtra("DELAY", String.valueOf(V2rayCoreManager.getInstance().getConnectedV2rayServerDelay()));
                sendBroadcast(sendB);
            }, "MEASURE_CONNECTED_V2RAY_SERVER_DELAY").start();
        } else {
            this.onDestroy();
        }
        return START_STICKY;
    }

    private void stopAllProcess() {
        if (stopping) return;
        stopping = true;
        stopForeground(true);
        isRunning = false;
        if (process != null) {
            process.destroy();
        }
        V2rayCoreManager.getInstance().stopCore();
        try {
            stopSelf();
        } catch (Exception e) {
            //ignore
            Log.e("CANT_STOP", "SELF");
        }
        try {
            mInterface.close();
        } catch (Exception e) {
            // ignored
        }

    }

    private void setup() {
        Intent prepare_intent = prepare(this);
        if (prepare_intent != null) {
            Log.e("VPN_SERVICE", "VpnService permission is not prepared");
            V2rayCoreManager.getInstance().markTunnelFailed("VpnService permission is not prepared");
            return;
        }
        Builder builder = new Builder();
        builder.setSession(v2rayConfig.REMARK);
        builder.setMtu(1500);
        builder.addAddress("10.0.0.1", 30);

        if (v2rayConfig.BYPASS_SUBNETS == null || v2rayConfig.BYPASS_SUBNETS.isEmpty()) {
            builder.addRoute("0.0.0.0", 0);
            builder.addRoute("::", 0);
        } else {
            for (String subnet : v2rayConfig.BYPASS_SUBNETS) {
                String[] parts = subnet.split("/");
                if (parts.length == 2) {
                    String address = parts[0];
                    int prefixLength = Integer.parseInt(parts[1]);
                    builder.addRoute(address, prefixLength);
                }
            }
        }
        if (v2rayConfig.BLOCKED_APPS != null) {
            for (int i = 0; i < v2rayConfig.BLOCKED_APPS.size(); i++) {
                try {
                    builder.addDisallowedApplication(v2rayConfig.BLOCKED_APPS.get(i));
                } catch (Exception e) {
                    //ignore
                }
            }
        }
        try {
            // Keep Xray and tun2socks sockets outside the VPN. Without this,
            // their localhost SOCKS connection can be captured by the TUN again.
            builder.addDisallowedApplication(getPackageName());
        } catch (Exception e) {
            Log.w("VPN_SERVICE", "Unable to exclude VPN application", e);
        }
        try {
            JSONObject json = new JSONObject(v2rayConfig.V2RAY_FULL_JSON_CONFIG);
            JSONObject dnsObject = json.getJSONObject("dns");
            JSONArray serversArray = dnsObject.getJSONArray("servers");
            for (int i = 0; i < serversArray.length(); i++) {
                String server = serversArray.getString(i);
                builder.addDnsServer(server);
            }
        } catch (JSONException e) {
            e.printStackTrace();
        }
        try {
            mInterface.close();
        } catch (Exception e) {
            //ignore
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            builder.setMetered(false);
            builder.setHttpProxy(ProxyInfo.buildDirectProxy("127.0.0.1", v2rayConfig.LOCAL_HTTP_PORT));
        }

        try {
            mInterface = builder.establish();
            if (mInterface == null) {
                throw new IllegalStateException("VpnService.Builder.establish returned null");
            }
            isRunning = true;
            runTun2socks();
        } catch (Exception e) {
            Log.e("VPN_SERVICE", "Unable to establish TUN interface", e);
            V2rayCoreManager.getInstance().markTunnelFailed("TUN establish failed: " + e.getMessage());
            stopAllProcess();
        }

    }

    private void runTun2socks() {
        File socketFile = new File(getApplicationContext().getFilesDir(), "sock_path");
        if (socketFile.exists() && !socketFile.delete()) {
            Log.w("VPN_SERVICE", "Unable to remove stale tun2socks socket");
        }
        ArrayList<String> cmd = new ArrayList<>(Arrays.asList(new File(getApplicationInfo().nativeLibraryDir, "libtun2socks.so").getAbsolutePath(),
                "--netif-ipaddr", "10.0.0.2",
                "--netif-netmask", "255.255.255.252",
                "--socks-server-addr", "127.0.0.1:" + v2rayConfig.LOCAL_SOCKS5_PORT,
                "--tunmtu", "1500",
                "--sock-path", socketFile.getAbsolutePath(),
                "--enable-udprelay",
                "--loglevel", "error"));
        try {
            ProcessBuilder processBuilder = new ProcessBuilder(cmd);
            processBuilder.redirectErrorStream(true);
            final Process startedProcess = processBuilder.directory(getApplicationContext().getFilesDir()).start();
            process = startedProcess;
            new Thread(() -> {
                try (InputStream input = startedProcess.getInputStream()) {
                    byte[] buffer = new byte[1024];
                    int count;
                    while ((count = input.read(buffer)) != -1) {
                        Log.d("TUN2SOCKS", new String(buffer, 0, count));
                    }
                } catch (Exception ignored) {
                }
            }, "Tun2socks_Log_Thread").start();
            new Thread(() -> {
                try {
                    startedProcess.waitFor();
                    if (isRunning) {
                        Log.e("TUN2SOCKS", "tun2socks exited unexpectedly: " + startedProcess.exitValue());
                        V2rayCoreManager.getInstance().markTunnelFailed(
                                "tun2socks exited with code " + startedProcess.exitValue());
                        stopAllProcess();
                    }
                } catch (InterruptedException e) {
                    //ignore
                }
            }, "Tun2socks_Thread").start();
            sendFileDescriptor();
        } catch (Exception e) {
            Log.e("VPN_SERVICE", "FAILED=>", e);
            this.onDestroy();
        }
    }

    private void sendFileDescriptor() {
        String localSocksFile = new File(getApplicationContext().getFilesDir(), "sock_path").getAbsolutePath();
        FileDescriptor tunFd = mInterface.getFileDescriptor();
        new Thread(() -> {
            Exception lastError = null;
            for (int tries = 0; tries < 30 && isRunning; tries++) {
                LocalSocket clientLocalSocket = null;
                try {
                    Thread.sleep(50L * (tries + 1));
                    clientLocalSocket = new LocalSocket();
                    clientLocalSocket.connect(new LocalSocketAddress(localSocksFile, LocalSocketAddress.Namespace.FILESYSTEM));
                    if (!clientLocalSocket.isConnected()) {
                        Log.e("SOCK_FILE", "Unable to connect to localSocksFile [" + localSocksFile + "]");
                    } else {
                        Log.e("SOCK_FILE", "connected to sock file [" + localSocksFile + "]");
                    }
                    OutputStream clientOutStream = clientLocalSocket.getOutputStream();
                    clientLocalSocket.setFileDescriptorsForSend(new FileDescriptor[]{tunFd});
                    clientOutStream.write(42);
                    clientOutStream.flush();
                    V2rayCoreManager.getInstance().markTunnelReady();
                    Log.i("TUN2SOCKS", "TUN file descriptor delivered successfully");
                    try {
                        clientLocalSocket.shutdownOutput();
                    } catch (Exception ignored) {
                    }
                    return;
                } catch (Exception e) {
                    lastError = e;
                    Log.e(V2rayVPNService.class.getSimpleName(), "sendFd failed =>", e);
                } finally {
                    if (clientLocalSocket != null) {
                        try {
                            clientLocalSocket.close();
                        } catch (Exception ignored) {
                        }
                    }
                }
            }
            Log.e(V2rayVPNService.class.getSimpleName(), "Unable to send VPN file descriptor to tun2socks");
            V2rayCoreManager.getInstance().markTunnelFailed(
                    "TUN FD delivery failed: " + (lastError == null ? "unknown error" : lastError.getMessage()));
            stopAllProcess();
        }, "sendFd_Thread").start();
    }


    @Override
    public void onDestroy() {
        super.onDestroy();
    }

    @Override
    public void onRevoke() {
        stopAllProcess();
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
        setup();
    }

    @Override
    public void stopService() {
        stopAllProcess();
    }
}
