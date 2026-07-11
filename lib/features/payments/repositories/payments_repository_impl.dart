import 'package:dio/dio.dart';
import 'package:vpn_app/core/api/api_service.dart';
import 'package:vpn_app/core/api/coco_api.dart';
import 'package:vpn_app/core/cache/memory_cache.dart';
import 'package:vpn_app/core/errors/error_mapper.dart';
import '../models/domain/payment.dart';
import '../models/domain/payment_method.dart';
import '../models/domain/payment_status.dart';
import 'payments_repository.dart';

class PaymentsRepositoryImpl implements PaymentsRepository {
  PaymentsRepositoryImpl(this.api, {this.statusTtl = const Duration(seconds: 45)});
  final ApiService api;
  final Duration statusTtl;
  final Map<String, MemoryCache<PaymentStatus>> _statusCache = {};

  @override
  Future<Payment> create({required double amount, required PaymentMethod method, int? planId, CancelToken? cancelToken}) async {
    try {
      if (planId == null) throw const FormatException('请选择套餐');
      await CocoApi(api).buyPlan(planId);
      return Payment(id: 'coco-$planId-${DateTime.now().millisecondsSinceEpoch}', status: PaymentStatus.succeeded, method: method, amount: amount);
    } on DioException catch (error) {
      throw mapDioError(error);
    }
  }

  @override
  Future<PaymentStatus> getStatus(String paymentId, {CancelToken? cancelToken}) async {
    final cache = _statusCache.putIfAbsent(paymentId, () => MemoryCache<PaymentStatus>());
    const status = PaymentStatus.succeeded;
    cache.set(status);
    return status;
  }

  @override
  Stream<PaymentStatus> pollStatus(String paymentId, {CancelToken? cancelToken}) async* {
    const status = PaymentStatus.succeeded;
    _statusCache.putIfAbsent(paymentId, () => MemoryCache<PaymentStatus>()).set(status);
    yield status;
  }
}
