package com.github.blueboytm.flutter_v2ray.v2ray;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.util.Log;

import com.github.blueboytm.flutter_v2ray.v2ray.utils.AppConfigs;

import java.util.ArrayList;

public class V2rayReceiver extends BroadcastReceiver {
    public interface Listener {
        void onStatus(ArrayList<String> status, String queryId);

        void onDelay(long delay, String queryId);
    }

    private final Listener listener;

    public V2rayReceiver(Listener listener) {
        this.listener = listener;
    }

    @Override
    public void onReceive(Context context, Intent intent) {
        try {
            if (AppConfigs.CONNECTED_SERVER_DELAY_ACTION.equals(intent.getAction())) {
                listener.onDelay(
                        intent.getLongExtra("DELAY", -1L),
                        intent.getStringExtra("QUERY_ID"));
                return;
            }
            ArrayList<String> list = new ArrayList<>();
            list.add(intent.getStringExtra("DURATION") == null ? "00:00:00" : intent.getStringExtra("DURATION"));
            list.add(String.valueOf(intent.getLongExtra("UPLOAD_SPEED", 0)));
            list.add(String.valueOf(intent.getLongExtra("DOWNLOAD_SPEED", 0)));
            list.add(String.valueOf(intent.getLongExtra("UPLOAD_TRAFFIC", 0)));
            list.add(String.valueOf(intent.getLongExtra("DOWNLOAD_TRAFFIC", 0)));
            Object rawState = intent.getSerializableExtra("STATE");
            String state = rawState == null ? "V2RAY_DISCONNECTED" : rawState.toString();
            list.add(state.startsWith("V2RAY_") ? state.substring(6) : state);
            list.add(intent.getStringExtra("ERROR") == null ? "" : intent.getStringExtra("ERROR"));
            list.add(intent.getStringExtra("SESSION_ID") == null ? "" : intent.getStringExtra("SESSION_ID"));
            list.add(String.valueOf(intent.getLongExtra("GENERATION", 0L)));
            listener.onStatus(list, intent.getStringExtra("QUERY_ID"));
        } catch (Exception e) {
            Log.e("V2rayReceiver", "onReceive failed", e);
        }
    }

}
