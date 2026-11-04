import 'dart:async';
import 'dart:io';

import 'package:sqflite/sqflite.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

enum UserFacingErrorCategory { localStorage, network, serverRejection, unknown }

/// Only typed classifications and fixed, safe messages cross the UI boundary.
/// Exception text is never used as a user-facing message.
class UserFacingError {
  const UserFacingError._(this.category, this.message);
  final UserFacingErrorCategory category;
  final String message;

  static const localStorageMessage =
      'تعذر قراءة البيانات المحفوظة على هذا الجهاز. أعد فتح التطبيق وحاول مرة أخرى.';
  static const networkMessage =
      'تعذر الاتصال. تحقق من الإنترنت ثم أعد المحاولة.';
  static const unknownMessage = 'تعذر إكمال العملية. حاول مرة أخرى.';

  factory UserFacingError.from(Object? error) {
    if (error is DatabaseException || error is FileSystemException) {
      return const UserFacingError._(
        UserFacingErrorCategory.localStorage,
        localStorageMessage,
      );
    }
    if (error is SocketException ||
        error is HttpException ||
        error is HandshakeException ||
        error is TimeoutException ||
        error is AuthRetryableFetchException) {
      return const UserFacingError._(
        UserFacingErrorCategory.network,
        networkMessage,
      );
    }
    if (error is PostgrestException || error is AuthException) {
      final forbidden = error is PostgrestException && error.code == '42501';
      return UserFacingError._(
        UserFacingErrorCategory.serverRejection,
        forbidden ? 'ليست لديك صلاحية لإكمال هذه العملية.' : 'تعذر إكمال العملية بالبيانات الحالية. راجع البيانات وحاول مرة أخرى.',
      );
    }
    return const UserFacingError._(
      UserFacingErrorCategory.unknown,
      unknownMessage,
    );
  }
}
