import 'dart:convert';

enum NasActorGender {
  male('male'),
  female('female'),
  unknown('unknown');

  const NasActorGender(this.wireValue);

  final String wireValue;

  static NasActorGender? tryParse(Object? value) => switch (value) {
    'male' => NasActorGender.male,
    'female' => NasActorGender.female,
    'unknown' => NasActorGender.unknown,
    _ => null,
  };
}

class NasMovieActor {
  const NasMovieActor({required this.name, required this.gender});

  final String name;
  final NasActorGender gender;

  Map<String, Object> toJson() => {
    'name': name,
    'gender': gender.wireValue,
  };

  static NasMovieActor? fromStoredJson(Object? value) {
    if (value is String) {
      final name = value.trim();
      return name.isEmpty
          ? null
          : NasMovieActor(name: name, gender: NasActorGender.unknown);
    }
    if (value is! Map) return null;
    final rawName = value['name'];
    if (rawName is! String || rawName.trim().isEmpty) return null;
    return NasMovieActor(
      name: rawName.trim(),
      gender: NasActorGender.tryParse(value['gender']) ?? NasActorGender.unknown,
    );
  }
}

List<NasMovieActor> normalizeNasMovieActors(Iterable<NasMovieActor> actors) {
  final normalized = <String, NasMovieActor>{};
  for (final actor in actors) {
    final name = actor.name.trim();
    if (name.isEmpty) continue;
    final key = name.toLowerCase();
    final candidate = NasMovieActor(name: name, gender: actor.gender);
    final existing = normalized[key];
    if (existing == null ||
        (existing.gender == NasActorGender.unknown &&
            candidate.gender != NasActorGender.unknown)) {
      normalized[key] = candidate;
    }
  }
  return List.unmodifiable(normalized.values);
}

List<NasMovieActor> decodeNasMovieActors(String? value) {
  if (value == null || value.isEmpty) return const [];
  try {
    final decoded = jsonDecode(value);
    if (decoded is! List) return const [];
    return normalizeNasMovieActors(
      decoded.map(NasMovieActor.fromStoredJson).whereType(),
    );
  } on FormatException {
    return const [];
  }
}

String encodeNasMovieActors(Iterable<NasMovieActor> actors) => jsonEncode(
  normalizeNasMovieActors(actors).map((actor) => actor.toJson()).toList(),
);

List<Map<String, Object>> nasMovieActorsToJson(
  Iterable<NasMovieActor> actors,
) => normalizeNasMovieActors(actors).map((actor) => actor.toJson()).toList();
