import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../errors/exceptions.dart';
import 'api_service.dart';

final cocoApiProvider = Provider<CocoApi>((ref) {
  return CocoApi(ref.read(apiServiceProvider));
}, name: 'cocoApi');

class CocoUserInfo {
  final String username;
  final String email;
  final double balance;
  final int level;
  final int trafficTotal;
  final int trafficUsed;
  final DateTime? expiresAt;
  final bool canUse;
  final String subscriptionUrl;

  const CocoUserInfo({
    required this.username,
    required this.email,
    required this.balance,
    required this.level,
    required this.trafficTotal,
    required this.trafficUsed,
    required this.expiresAt,
    required this.canUse,
    required this.subscriptionUrl,
  });

  int get trafficRemaining =>
      (trafficTotal - trafficUsed).clamp(0, trafficTotal).toInt();

  factory CocoUserInfo.fromJson(Map<String, dynamic> json) {
    final traffic = _map(json['traffic']);
    return CocoUserInfo(
      username: json['username']?.toString() ?? '',
      email: json['true_name']?.toString() ?? '',
      balance: double.tryParse(json['balance']?.toString() ?? '') ?? 0,
      level: _int(json['class']),
      trafficTotal: _int(traffic['total']),
      trafficUsed: _int(traffic['used']),
      expiresAt: DateTime.tryParse(json['class_expire']?.toString() ?? ''),
      canUse: json['proxy_available'] == true,
      subscriptionUrl: json['profile_url']?.toString() ??
          json['pc_sub']?.toString() ??
          '',
    );
  }
}

class CocoPlan {
  final int id;
  final String name;
  final String type;
  final double price;
  final int trafficBytes;
  final int durationDays;
  final int level;
  final String description;

  const CocoPlan({
    required this.id,
    required this.name,
    required this.type,
    required this.price,
    required this.trafficBytes,
    required this.durationDays,
    required this.level,
    required this.description,
  });

  factory CocoPlan.fromJson(Map<String, dynamic> json) => CocoPlan(
        id: _int(json['id']),
        name: json['name']?.toString() ?? '套餐',
        type: json['type']?.toString() ?? 'monthly',
        price: double.tryParse(json['price']?.toString() ?? '') ?? 0,
        trafficBytes: _int(json['traffic_bytes']),
        durationDays: _int(json['duration_days']),
        level: _int(json['level']),
        description: json['description']?.toString() ?? '',
      );
}

class CocoAnnouncement {
  final int id;
  final String markdown;
  final DateTime? updatedAt;

  const CocoAnnouncement({required this.id, required this.markdown, this.updatedAt});

  factory CocoAnnouncement.fromJson(Map<String, dynamic> json) => CocoAnnouncement(
        id: _int(json['id']),
        markdown: json['markdown']?.toString() ?? '',
        updatedAt: DateTime.tryParse(json['updated_at']?.toString() ?? ''),
      );
}

class CocoApi {
  final ApiService _api;
  CocoApi(this._api);

  Future<CocoUserInfo> userInfo({CancelToken? cancelToken}) async {
    final res = await _api.get('/v1/userinfo',
        query: const {'fresh': '1'}, cancelToken: cancelToken);
    return CocoUserInfo.fromJson(_dataMap(res));
  }

  Future<List<CocoPlan>> plans({CancelToken? cancelToken}) async {
    final res = await _api.get('/v1/plans', cancelToken: cancelToken);
    final data = _dataMap(res);
    return _list(data['rows']).map((e) => CocoPlan.fromJson(_map(e))).toList();
  }

  Future<List<CocoAnnouncement>> announcements({CancelToken? cancelToken}) async {
    final res = await _api.get('/v1/anno', cancelToken: cancelToken);
    return _dataList(res).map((e) => CocoAnnouncement.fromJson(_map(e))).toList();
  }

  Future<CocoUserInfo> checkin() async {
    final res = await _api.post('/v1/checkin', data: const {});
    return CocoUserInfo.fromJson(_map(_dataMap(res)['user']));
  }

  Future<CocoUserInfo> recharge(String code) async {
    final res = await _api.post('/v1/recharge', data: {'code': code.trim()});
    return CocoUserInfo.fromJson(_map(_dataMap(res)['user']));
  }

  Future<CocoUserInfo> redeem(String code, {int? planId}) async {
    final res = await _api.post('/v1/redeem', data: {
      'code': code.trim(),
      if (planId != null) 'plan_id': planId,
    });
    return CocoUserInfo.fromJson(_map(_dataMap(res)['user']));
  }

  Future<CocoUserInfo> buyPlan(int planId) async {
    final res = await _api.post('/v1/buy-plan', data: {'plan_id': planId});
    return CocoUserInfo.fromJson(_map(_dataMap(res)['user']));
  }

  Future<String> subscriptionText({CancelToken? cancelToken}) async {
    final res = await _api.get<String>(
      '/v1/link',
      options: Options(responseType: ResponseType.plain),
      cancelToken: cancelToken,
    );
    if ((res.statusCode ?? 0) < 200 || (res.statusCode ?? 0) >= 300) {
      _throwResponse(res);
    }
    return res.data?.toString() ?? '';
  }
}

Map<String, dynamic> cocoEnvelope(Response response) {
  final status = response.statusCode ?? 0;
  final body = _map(response.data);
  final code = _int(body['code']);
  if (status < 200 || status >= 300 || (code != 0 && code != 200)) {
    _throwResponse(response);
  }
  return body;
}

Map<String, dynamic> _dataMap(Response response) => _map(cocoEnvelope(response)['data']);
List<dynamic> _dataList(Response response) => _list(cocoEnvelope(response)['data']);

Never _throwResponse(Response response) {
  final body = _map(response.data);
  final bodyCode = _int(body['code']);
  final status = bodyCode != 0 && bodyCode != 200
      ? bodyCode
      : (response.statusCode ?? bodyCode);
  final message = body['info']?.toString() ??
      body['msg']?.toString() ??
      body['message']?.toString() ??
      '请求失败 ($status)';
  if (status == 401) throw UnauthorizedException(message);
  throw ApiException(message, status);
}

Map<String, dynamic> _map(dynamic value) =>
    value is Map ? value.cast<String, dynamic>() : <String, dynamic>{};
List<dynamic> _list(dynamic value) => value is List ? value : const [];
int _int(dynamic value) => value is num ? value.toInt() : int.tryParse('$value') ?? 0;
