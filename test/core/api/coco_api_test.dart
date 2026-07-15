import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vpn_app/core/api/api_service.dart';
import 'package:vpn_app/core/api/coco_api.dart';

void main() {
  group('CocoApi.reportTraffic', () {
    test('posts the delta and parses a successful report', () async {
      final service = _StubApiService(
        _response(
          httpStatus: 200,
          code: 200,
          accepted: 2048,
          total: 10000,
          used: 4096,
          remaining: 5904,
          trafficLine: '流量：4 KB / 10 KB',
          reportId: 'report-2048',
          deduplicated: true,
        ),
      );

      final result = await CocoApi(
        service,
      ).reportTraffic(2048, reportId: 'report-2048');

      expect(service.lastPath, '/v1/traffic');
      expect(service.lastData, {'bytes': 2048, 'report_id': 'report-2048'});
      expect(service.lastOptions?.validateStatus?.call(402), isTrue);
      expect(result.accepted, 2048);
      expect(result.trafficTotal, 10000);
      expect(result.trafficUsed, 4096);
      expect(result.trafficRemaining, 5904);
      expect(result.trafficLine, '流量：4 KB / 10 KB');
      expect(result.statusCode, 200);
      expect(result.message, 'success');
      expect(result.restriction, isNull);
      expect(result.isRestricted, isFalse);
      expect(result.hasTrafficSnapshot, isTrue);
      expect(result.reportId, 'report-2048');
      expect(result.deduplicated, isTrue);
    });

    test('parses the optional account sync extension', () async {
      final service = _StubApiService(
        _response(
          httpStatus: 200,
          code: 200,
          accepted: 0,
          total: 1,
          used: 1,
          remaining: 0,
          trafficLine: '',
          account: {
            'status': 1,
            'class_expire': '2030-01-01T00:00:00Z',
            'sub_url': 'https://example.test/personal-sub',
            'updated_at': '2029-12-01T00:00:00Z',
            'traffic_total': 10000,
            'traffic_used': 2500,
          },
        ),
      );

      final result = await CocoApi(service).reportTraffic(0);

      expect(result.trafficTotal, 10000);
      expect(result.trafficUsed, 2500);
      expect(result.trafficRemaining, 7500);
      expect(result.account?.status, 1);
      expect(
        result.account?.subscriptionUrl,
        'https://example.test/personal-sub',
      );
      expect(result.account?.canUse, isTrue);
      expect(result.hasTrafficSnapshot, isTrue);
    });

    test('keeps traffic data when quota is exhausted with HTTP 402', () async {
      final service = _StubApiService(
        _response(
          httpStatus: 402,
          code: 402,
          info: '套餐流量已用完',
          accepted: 512,
          total: 4096,
          used: 4096,
          remaining: 0,
          trafficLine: '流量：4 KB / 4 KB',
        ),
      );

      final result = await CocoApi(
        service,
      ).reportTraffic(512, reportId: 'report-512');

      expect(result.accepted, 512);
      expect(result.trafficUsed, 4096);
      expect(result.trafficRemaining, 0);
      expect(result.message, '套餐流量已用完');
      expect(result.restriction, CocoTrafficRestriction.quotaOrExpired);
      expect(result.isRestricted, isTrue);
      expect(result.hasTrafficSnapshot, isTrue);
    });

    test(
      'keeps traffic data when account is disabled by response code 403',
      () async {
        final service = _StubApiService(
          _response(
            httpStatus: 200,
            code: 403,
            info: '账户已禁用',
            accepted: 0,
            total: 0,
            used: 0,
            remaining: 0,
            trafficLine: '流量：1 KB / 8 KB',
            includeTraffic: false,
          ),
        );

        final result = await CocoApi(service).reportTraffic(0);

        expect(result.statusCode, 403);
        expect(result.trafficTotal, 0);
        expect(result.trafficUsed, 0);
        expect(result.trafficRemaining, 0);
        expect(result.trafficLine, '流量：1 KB / 8 KB');
        expect(result.restriction, CocoTrafficRestriction.accountDisabled);
        expect(result.hasTrafficSnapshot, isFalse);
      },
    );

    test(
      'exposes an unauthorized response as an explicit restriction',
      () async {
        final service = _StubApiService(
          _response(
            httpStatus: 401,
            code: 401,
            info: '登录已失效',
            accepted: 0,
            total: 0,
            used: 0,
            remaining: 0,
            trafficLine: '',
            includeTraffic: false,
          ),
        );

        final result = await CocoApi(service).reportTraffic(0);

        expect(result.statusCode, 401);
        expect(result.message, '登录已失效');
        expect(result.restriction, CocoTrafficRestriction.unauthorized);
        expect(result.hasTrafficSnapshot, isFalse);
      },
    );
  });
}

Response<Map<String, dynamic>> _response({
  required int httpStatus,
  required int code,
  String info = 'success',
  required Object accepted,
  required Object total,
  required Object used,
  required Object remaining,
  required String trafficLine,
  bool includeTraffic = true,
  String? reportId,
  bool deduplicated = false,
  Map<String, dynamic>? account,
}) => Response<Map<String, dynamic>>(
  requestOptions: RequestOptions(path: '/v1/traffic'),
  statusCode: httpStatus,
  data: {
    'code': code,
    'info': info,
    'data': {
      'accepted': accepted,
      'report_id': reportId,
      'deduplicated': deduplicated,
      if (includeTraffic)
        'traffic': {'total': total, 'used': used, 'remaining': remaining},
      if (account != null) 'account': account,
      'traffic_line': trafficLine,
    },
  },
);

class _StubApiService extends ApiService {
  _StubApiService(this.response) : super(Dio());

  final Response<Map<String, dynamic>> response;
  String? lastPath;
  Object? lastData;
  Options? lastOptions;

  @override
  Future<Response<T>> post<T>(
    String path, {
    Object? data,
    Options? options,
    CancelToken? cancelToken,
  }) async {
    lastPath = path;
    lastData = data;
    lastOptions = options;
    return Response<T>(
      requestOptions: response.requestOptions,
      statusCode: response.statusCode,
      data: response.data as T,
    );
  }
}
