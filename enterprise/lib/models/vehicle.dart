class Vehicle {
  final String registrationPlate;
  final String vehicleType;

  Vehicle({required this.registrationPlate, required this.vehicleType});

  factory Vehicle.fromJson(Map<String, dynamic> json) => Vehicle(
        registrationPlate: (json['registration_plate'] ?? '').toString(),
        vehicleType: (json['vehicle_type'] ?? '').toString(),
      );

  @override
  String toString() => registrationPlate; // for dropdown labels
}
