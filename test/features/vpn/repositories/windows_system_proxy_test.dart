import 'package:flutter_test/flutter_test.dart';
import 'package:vpn_app/features/vpn/repositories/vpn_repository_impl.dart';

void main() {
  group('windowsProxyEnabledFromRegistry', () {
    test('reads disabled ProxyEnable value', () {
      expect(
        windowsProxyEnabledFromRegistry(_proxyEnableOutput('0x0')),
        isFalse,
      );
    });

    test('reads enabled ProxyEnable value', () {
      expect(
        windowsProxyEnabledFromRegistry(_proxyEnableOutput('0x1')),
        isTrue,
      );
    });
  });

  group('windowsSystemProxyEnabledFromRegistry', () {
    test('is false when ProxyEnable is zero but the core address remains', () {
      expect(
        windowsSystemProxyEnabledFromRegistry(
          _proxyEnableOutput('0x0'),
          _proxyServerOutput('127.0.0.1:7890'),
        ),
        isFalse,
      );
    });

    test('is true for enabled core proxy address', () {
      expect(
        windowsSystemProxyEnabledFromRegistry(
          _proxyEnableOutput('0x1'),
          _proxyServerOutput('127.0.0.1:7890'),
        ),
        isTrue,
      );
    });

    test('is true when a multi-protocol proxy uses the core address', () {
      expect(
        windowsSystemProxyEnabledFromRegistry(
          _proxyEnableOutput('0x1'),
          _proxyServerOutput(
            'http=127.0.0.1:7890;https=127.0.0.1:7890;'
            'socks=127.0.0.1:7890',
          ),
        ),
        isTrue,
      );
    });

    test('is false when another system proxy is enabled', () {
      expect(
        windowsSystemProxyEnabledFromRegistry(
          _proxyEnableOutput('0x1'),
          _proxyServerOutput('proxy.example.com:8080'),
        ),
        isFalse,
      );
    });
  });
}

String _proxyEnableOutput(String value) =>
    'HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\'
    'Internet Settings\r\n'
    '    ProxyEnable    REG_DWORD    $value\r\n';

String _proxyServerOutput(String value) =>
    'HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\'
    'Internet Settings\r\n'
    '    ProxyServer    REG_SZ    $value\r\n';
