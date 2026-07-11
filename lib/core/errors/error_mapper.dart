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
    } else if (data['info'] != null) {
      msg = data['info'].toString();
    }
  }

  msg ??= '\u9519\u8bef: $status';
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
      return const ApiException('\u7f51\u7edc\u8fde\u63a5\u95ee\u9898\uff0c\u8bf7\u68c0\u67e5\u7f51\u7edc\u8bbe\u7f6e\u3002');
    case DioExceptionType.badCertificate:
      return const ApiException('\u8fde\u63a5\u8bc1\u4e66\u9a8c\u8bc1\u5931\u8d25\u3002');
    case DioExceptionType.cancel:
      return const ApiException('\u8bf7\u6c42\u5df2\u88ab\u7528\u6237\u53d6\u6d88\u3002');
    case DioExceptionType.badResponse:
      return ApiException(
        e.message ?? '\u670d\u52a1\u5668\u54cd\u5e94\u9519\u8bef',
        e.response?.statusCode,
      );
    case DioExceptionType.unknown:
      return ApiException(e.message ?? '\u672a\u77e5\u9519\u8bef', e.response?.statusCode);
  }
}
