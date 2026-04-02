/// Singleton class to manage authenticated user session data
class UserSession {
  static final UserSession _instance = UserSession._internal();

  factory UserSession() => _instance;

  UserSession._internal();

  int? _userId;
  String? _userName;
  String? _role;
  int? _glpiUserId;

  /// Set the authenticated user data
  void setUser({
    required int userId,
    required String userName,
    required String role,
    required int glpiUserId,
  }) {
    _userId = userId;
    _userName = userName;
    _role = role;
    _glpiUserId = glpiUserId;
  }

  /// Get the current user data as a map
  Map<String, dynamic>? getUser() {
    if (_userId == null || _userName == null || _role == null) {
      return null;
    }
    return {
      'user_id': _userId,
      'name': _userName,
      'role': _role,
      'glpi_user_id': _glpiUserId,
    };
  }

  /// Clear the session
  void clear() {
    _userId = null;
    _userName = null;
    _role = null;
    _glpiUserId = null;
  }

  /// Check if the logged-in user has a specific role
  bool isRole(String role) {
    return _role?.toLowerCase() == role.toLowerCase();
  }

  /// Check if user is tivit role
  bool get isTivit => isRole('tivit') || isRole('admin');

  /// Check if user is admin role
  bool get isAdmin => isRole('admin');

  /// Get the GLPI user ID
  int? get glpiUserId => _glpiUserId;

  /// Get the user name
  String? get userName => _userName;

  /// Get the role
  String? get role => _role;
}
