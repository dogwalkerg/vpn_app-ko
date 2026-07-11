// lib/features/auth/repositories/auth_repository_impl.dart
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_service.dart';
import '../../../core/errors/error_mapper.dart';
import '../../../core/errors/exceptions.dart';
import '../../../core/api/coco_api.dart';
import '../models/dto/user_dto.dart';
import '../mappers/user_mapper.dart';
import '../models/domain/user.dart';
import '../models/domain/login_result.dart';
import 'auth_repository.dart';

final authRepositoryProvider = Provider<AuthRepository>((ref) {
  final api = ref.read(apiServiceProvider);
  return AuthRepositoryImpl(api);
});

class AuthRepositoryImpl implements AuthRepository {
  final ApiService api;
  AuthRepositoryImpl(this.api);

  @override
  Future<LoginResult> login({required String username, required String password, CancelToken? cancelToken}) async {
    final res = await api.post('/v1/login', data: {'username': username, 'password': password}, cancelToken: cancelToken);
    final code = res.statusCode ?? 0;
    if (code >= 200 && code < 300) {
      final data = cocoEnvelope(res)['data'];
      final userMap = data is Map ? data.cast<String, dynamic>() : <String, dynamic>{};
      final token = userMap['token']?.toString();
      if (token == null || token.isEmpty) {
        throwFromResponse(res);
      }
      final dto = UserDto.fromJson(userMap);
      final user = userFromDto(dto);
      return LoginResult(token: token, user: user);
    }
    throwFromResponse(res);
  }

  @override
  Future<void> register({required String username, required String email, required String password, CancelToken? cancelToken}) async {
    final res = await api.post('/v1/register', data: {'username': username, 'email': email, 'password': password}, cancelToken: cancelToken);
    final code = res.statusCode ?? 0;
    if (code < 200 || code >= 300) throwFromResponse(res);
  }

  @override
  Future<void> verifyEmail({required String username, required String email, required String verificationCode, CancelToken? cancelToken}) async {
    throw const ApiException('当前后台注册后立即生效，无需邮箱验证码。');
  }

  @override
  Future<void> logout({CancelToken? cancelToken}) async {
    final res = await api.get('/v1/logout', cancelToken: cancelToken);
    final code = res.statusCode ?? 0;
    if (code < 200 || code >= 300) throwFromResponse(res);
  }

  @override
  Future<User> validateToken({CancelToken? cancelToken}) async {
    final res = await api.get('/v1/userinfo', query: const {'fresh': '1'}, cancelToken: cancelToken);
    final code = res.statusCode ?? 0;
    if (code >= 200 && code < 300) {
      final raw = cocoEnvelope(res)['data'];
      final data = raw is Map ? raw.cast<String, dynamic>() : <String, dynamic>{};
      final dto = UserDto.fromJson(data);
      return userFromDto(dto);
    }
    throwFromResponse(res);
  }

  @override
  Future<void> forgotPassword(String username, {CancelToken? cancelToken}) async {
    throw const ApiException('当前后台未启用自助找回密码，请联系管理员重置。');
  }

  @override
  Future<void> resetPassword({required String username, required String resetCode, required String newPassword, CancelToken? cancelToken}) async {
    throw const ApiException('当前后台未启用自助重置密码，请联系管理员。');
  }
}

