// lib/features/payments/models/dto/payment_dto.dart
import '../domain/payment.dart';
import '../domain/payment_method.dart';
import '../domain/payment_status.dart';

class PaymentInitDto {
  final String id;
  final String confirmationUrl;
  final PaymentStatus status;
  final PaymentMethod? method;
  final double? amount;

  PaymentInitDto({
    required this.id,
    required this.confirmationUrl,
    required this.status,
    this.method,
    this.amount,
  });

  factory PaymentInitDto.fromMap(Map<String, dynamic> map) {
    final pid = map['paymentId'] as String?;
    if (pid == null || pid.isEmpty) {
      throw const FormatException('支付初始化数据无效');
    }

    return PaymentInitDto(
      id: pid,
      confirmationUrl: (map['confirmationUrl'] as String?) ?? '',
      status: parsePaymentStatus((map['status'] as String?) ?? 'pending'),
      method: _methodFromRawOrNull(map['method'] as String?),
      amount: (map['amount'] as num?)?.toDouble(),
    );
  }

  Payment toDomain() => Payment(
        id: id,
        status: status,
        confirmationUrl: confirmationUrl,
        method: method,
        amount: amount,
      );
}

PaymentMethod? _methodFromRawOrNull(String? raw) {
  switch (raw) {
    case 'balance':
      return PaymentMethod.balance;
    default:
      return null;
  }
}
