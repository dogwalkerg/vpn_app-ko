// lib/features/payments/models/domain/payment_method.dart
enum PaymentMethod { balance }

extension PaymentMethodApiX on PaymentMethod {
  String get serverValue {
    switch (this) {
      case PaymentMethod.balance:
        return 'balance';
    }
  }
}
