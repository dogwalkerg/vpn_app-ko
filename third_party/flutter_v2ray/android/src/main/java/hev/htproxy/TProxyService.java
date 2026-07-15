package hev.htproxy;

public final class TProxyService {
    static {
        System.loadLibrary("hev-socks5-tunnel");
    }

    public native void TProxyStartService(String configPath, int tunFd);

    public native void TProxyStopService();

    public native long[] TProxyGetStats();
}
