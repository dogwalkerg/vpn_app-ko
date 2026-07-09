// lib/core/errors/error_mapper.dart
import 'package:dio/dio.dart';
import 'exceptions.dart';

Never throwFromResponse(Response res) {
  final status = res.statusCode ?? 0;
  String? code;
  String? msg;

  final data = res.data;
  if (data is Map) {
    if (data['error'] is Map) {
      final err = data['error'] as Map;
      code = err['code']?.toString();
      msg = err['message']?.toString();
    } else if (data['error'] != null) {
      msg = data['error'].toString();
    } else if (data['message'] != null) {
      msg = data['message'].toString();
    }
  }

  msg ??= '错误: $status';
  if (status == 401) throw UnauthorizedException(msg);
  throw ApiException(msg, status, code);
}

ApiException mapDioError(DioException e) {
  switch (e.type) {
    case DioExceptionType.connectionTimeout:
    case DioExceptionType.receiveTimeout:
    case DioExceptionType.sendTimeout:
    case DioExceptionType.connectionError:
    case DioExceptionType.transformTimeout:
      return const ApiException('网络连接问题，请检查网络设置。');
    case DioExceptionType.badCertificate:
      return const ApiException('连接证书验证失败。');
    case DioExceptionType.cancel:
      return const ApiException('请求已被用户取消。');
    case DioExceptionType.badResponse:
      return ApiException(
        e.message ?? '服务器响应错误',
        e.response?.statusCode,
      );
    case DioExceptionType.unknown:
      return ApiException(e.message ?? '未知错误', e.response?.statusCode);
  }
}