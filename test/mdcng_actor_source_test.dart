import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import '../lib/src/library/mdcng_actor_source.dart';

Future<void> main() async {
  final directory =
      await Directory.systemTemp.createTemp('mujing-nas-mdcng-actor-source-');
  final data = Directory('${directory.path}${Platform.pathSeparator}data');
  final photos = Directory(
    '${data.path}${Platform.pathSeparator}photos${Platform.pathSeparator}graphis',
  );
  await photos.create(recursive: true);
  try {
    _createTaskDatabase('${data.path}${Platform.pathSeparator}mdc_ng.db');
    _createProfileDatabase('${data.path}${Platform.pathSeparator}Actress.db');
    await File('${photos.path}${Platform.pathSeparator}涼森れむ-old.jpg')
        .writeAsBytes(const [0xff, 0xd8, 0xff, 0xd9]);
    await File('${photos.path}${Platform.pathSeparator}涼森れむ-big-old.jpg')
        .writeAsBytes(const [0xff, 0xd8, 0xff, 0xd9]);
    await File('${photos.path}${Platform.pathSeparator}涼森れな-big-old.jpg')
        .writeAsBytes(const [0xff, 0xd8, 0xff, 0xd9]);
    await File('${photos.path}${Platform.pathSeparator}涼森れむ子.jpg')
        .writeAsBytes(const [0xff, 0xd8, 0xff, 0xd9]);
    await File('${photos.path}${Platform.pathSeparator}AI-Fix-凉森玲梦-old.jpg')
        .writeAsBytes(const [0xff, 0xd8, 0xff, 0xd9]);
    await File(
            '${photos.path}${Platform.pathSeparator}AI-Fix-Abigaile Johnson.jpg')
        .writeAsBytes(const [0xff, 0xd8, 0xff, 0xd9]);
    await File('${photos.path}${Platform.pathSeparator}柏木こなつ.jpg')
        .writeAsBytes(const [0xff, 0xd8, 0xff, 0xd9]);
    final mappingFile =
        File('${data.path}${Platform.pathSeparator}mapping_actor.xml');
    await mappingFile.writeAsString('''
<actor>
  <a zh_cn="凉森玲梦" zh_tw="涼森玲夢" jp="涼森れむ" keyword=",凉森玲梦,涼森れむ,"/>
</actor>
''');
    final profiles = sqlite3.open(
      '${data.path}${Platform.pathSeparator}Actress.db',
    );
    try {
      profiles.execute(
        'INSERT INTO Info(Name, Href) VALUES (?, ?)',
        ['涼森れな', 'actress-other'],
      );
    } finally {
      profiles.dispose();
    }

    final source = NasMdcngActorSource(data.path);
    final records = await source.readCompletedActors();
    _expect(records.length == 1, 'only completed actor tasks are returned');
    _expect(records.single.profileResolution == 'raw',
        'imports translated task names without requiring a profile match');
    _expect(records.single.profile == null,
        'keeps optional Actress.db fields empty without a match');
    _expect(records.single.photo?.fileName == 'AI-Fix-凉森玲梦-old.jpg',
        'finds AI-repaired images by the raw MDCNG task name');
    final candidate = records.single.candidates
        .where((candidate) => candidate.name == '涼森れむ')
        .single;
    _expect(candidate.key.isNotEmpty,
        'suggests the shared-name-prefix profile for an explicit choice');
    _expect(candidate.hasPhoto, 'portrait candidate is marked');
    _expect(candidate.missingFieldCount == 0,
        'complete candidate has no missing profile fields');
    _expect(
      records.single.candidates
              .where((candidate) => candidate.name == '涼森れな')
              .single
              .missingFieldCount ==
          12,
      'sparse candidate reports missing profile fields',
    );
    _expect(
      !records.single.candidates
          .where((candidate) => candidate.name == '涼森れな')
          .single
          .hasPhoto,
      'a backdrop-only candidate is not marked as having a portrait',
    );

    final selectedRecords = await source.readCompletedActors(
      selectedProfileKeys: {'1': candidate.key},
    );
    final record = selectedRecords.single;
    _expect(record.embyId == '1536', 'retains the MDCNG Emby person id');
    _expect(record.profileResolution == 'matched', 'uses the explicit profile');
    _expect(record.selectedProfileKey == candidate.key,
        'retains explicit profile selection');
    _expect(record.profile?.name == '涼森れむ', 'matches the actress profile');
    _expect(record.profile?.birthMonth == '1997-12', 'derives birth month');
    _expect(
        record.profile?.measurements == 'B87 / W58 / H85', 'maps measurements');
    _expect(record.profile?.debutMonth == '2019-03', 'derives debut month');
    _expect(record.photo?.fileName == '涼森れむ-old.jpg', 'finds portrait image');
    _expect(!record.images.any((image) => image.fileName == '涼森れむ子.jpg'),
        'does not assign a longer actor name as this actor portrait');
    _expect(
      record.backdrop?.fileName == '涼森れむ-big-old.jpg',
      'finds backdrop image',
    );
    _expect(record.fingerprint.length == 64,
        'returns a stable preview fingerprint');
    final otherCandidate = records.single.candidates
        .where((candidate) => candidate.name == '涼森れな')
        .single;
    final manuallyChanged = (await source.readCompletedActors(
      selectedProfileKeys: {'1': otherCandidate.key},
    ))
        .single;
    _expect(manuallyChanged.photo == null,
        'manual choice of another profile does not borrow task portrait');
    _expect(manuallyChanged.backdrop?.fileName == '涼森れな-big-old.jpg',
        'manual choice still uses its own image');
    await File('${photos.path}${Platform.pathSeparator}涼森れむ-old.jpg')
        .writeAsBytes(const [0], mode: FileMode.append);
    final cached = await source.readCompletedActors(
      selectedProfileKeys: {'1': candidate.key},
    );
    _expect(cached.single.fingerprint == record.fingerprint,
        'repeated reviews reuse image metadata without touching the disk');
    final refreshed = await source.readCompletedActors(
      selectedProfileKeys: {'1': candidate.key},
      forceRefresh: true,
    );
    _expect(refreshed.single.fingerprint != record.fingerprint,
        'apply refreshes the source fingerprint after an image changes');

    await File('${photos.path}${Platform.pathSeparator}AI-Fix-凉森玲梦-old.jpg')
        .delete();
    final mapped =
        (await source.readCompletedActors(forceRefresh: true)).single;
    _expect(mapped.profileResolution == 'raw',
        'image mapping does not force a profile choice');
    _expect(mapped.photo?.fileName == '涼森れむ-old.jpg',
        'MDCNG name mapping finds the Japanese-named portrait');
    await mappingFile.writeAsString('''
<actor>
  <a zh_cn="凉森玲梦" jp="涼森れむ" keyword=",凉森玲梦,"/>
  <a zh_cn="凉森玲梦" jp="别的演员" keyword=",凉森玲梦,"/>
</actor>
''');
    final ambiguous =
        (await source.readCompletedActors(forceRefresh: true)).single;
    _expect(ambiguous.photo == null,
        'ambiguous source name cannot borrow another actor portrait');

    final tasksWithEnglishName = sqlite3.open(
      '${data.path}${Platform.pathSeparator}mdc_ng.db',
    );
    try {
      tasksWithEnglishName.execute('''
        INSERT INTO actress_task(id, name, status, stage, emby_id, has_pic)
        VALUES (2002, 'Abigaile Johnson', 2, 1000, 'english-actor', 1)
      ''');
    } finally {
      tasksWithEnglishName.dispose();
    }
    final englishName = (await source.readCompletedActors(forceRefresh: true))
        .where((item) => item.taskId == '2002')
        .single;
    _expect(englishName.photo?.fileName == 'AI-Fix-Abigaile Johnson.jpg',
        'a name containing big is still classified as a portrait');
    _expect(englishName.backdrop == null,
        'an English name does not create a false backdrop');

    await mappingFile.writeAsString('''
<actor>
  <a zh_cn="柏木小夏" jp="柏木こなつ" keyword=",柏木小夏,柏木こなつ,"/>
  <a zh_cn="柏木こなつ" jp="柏木こなつ" keyword=",柏木こなつ,"/>
</actor>
''');
    final taskWithSharedCanonicalName = sqlite3.open(
      '${data.path}${Platform.pathSeparator}mdc_ng.db',
    );
    try {
      taskWithSharedCanonicalName.execute('''
        INSERT INTO actress_task(id, name, status, stage, emby_id, has_pic)
        VALUES (2003, '柏木小夏', 2, 1000, 'canonical-actor', 1)
      ''');
    } finally {
      taskWithSharedCanonicalName.dispose();
    }
    final sharedCanonical =
        (await source.readCompletedActors(forceRefresh: true))
            .where((item) => item.taskId == '2003')
            .single;
    _expect(sharedCanonical.photo?.fileName == '柏木こなつ.jpg',
        'reuses a shared canonical Japanese name without sharing aliases');

    _addManyActors(data.path, 1000);
    final largeRead = Stopwatch()..start();
    final manyRecords = await source.readCompletedActors(forceRefresh: true);
    largeRead.stop();
    _expect(
        manyRecords.length == 1003, 'reads over a thousand completed actors');
    _expect(
        manyRecords
                .where((item) => item.taskId == '500')
                .single
                .profile
                ?.name ==
            '测试演员500',
        'resolves a profile in the large indexed source');
    final tasks = sqlite3.open(
      '${data.path}${Platform.pathSeparator}mdc_ng.db',
    );
    try {
      tasks.execute(
        'UPDATE actress_task SET overview = ? WHERE id = 1',
        ['Twitter: https://example.invalid/social'],
      );
    } finally {
      tasks.dispose();
    }
    final linkedByUrl = (await source.readCompletedActors(forceRefresh: true))
        .where((item) => item.taskId == '1')
        .single;
    _expect(linkedByUrl.profile?.name == '涼森れむ',
        'a unique external profile URL links a translated task name');
    _expect(linkedByUrl.photo?.fileName == '涼森れむ-old.jpg',
        'a linked profile contributes its native-name portrait');
    stdout.writeln(
        '1003 actor source records: ${largeRead.elapsedMilliseconds} ms');
  } finally {
    await directory.delete(recursive: true);
  }
  stdout.writeln('mdcng_actor_source_test: PASS');
}

void _createTaskDatabase(String path) {
  final database = sqlite3.open(path);
  try {
    database.execute('''
      CREATE TABLE actress_task (
        id INTEGER PRIMARY KEY,
        name TEXT NOT NULL,
        status INTEGER NOT NULL,
        stage INTEGER NOT NULL,
        emby_id TEXT,
        year INTEGER,
        has_pic INTEGER NOT NULL DEFAULT 0,
        has_backdrop INTEGER NOT NULL DEFAULT 0,
        overview TEXT,
        end_at TEXT
      );
      INSERT INTO actress_task(
        id, name, status, stage, emby_id, year, has_pic, has_backdrop, end_at
      ) VALUES (1, '凉森玲梦', 2, 1000, '1536', 1997, 1, 1,
        '2026-09-14T07:50:01.000000000+00:00');
      INSERT INTO actress_task(id, name, status, stage, emby_id)
        VALUES (2, '未完成', 1, 20, '999');
    ''');
  } finally {
    database.dispose();
  }
}

void _createProfileDatabase(String path) {
  final database = sqlite3.open(path);
  try {
    database.execute('''
      CREATE TABLE Info (
        Name TEXT, Roma TEXT, Href TEXT PRIMARY KEY, Birthday TEXT, Height INTEGER,
        Bust INTEGER, Waist INTEGER, Hip INTEGER, Cup TEXT, Birthplace TEXT,
        CareerPeriod TEXT, DebutWork TEXT, Account TEXT, OfficialSite TEXT,
        UpdateTime TEXT, Completeness INTEGER
      );
      CREATE TABLE Names (Alias TEXT PRIMARY KEY, Name TEXT, Roma TEXT);
      INSERT INTO Info(
        Name, Roma, Href, Birthday, Height, Bust, Waist, Hip, Cup, Birthplace,
        CareerPeriod, DebutWork, Account, OfficialSite, UpdateTime, Completeness
      ) VALUES (
        '涼森れむ', 'Suzumori Remu', 'actress533604.html?涼森れむ',
        '1997-12-03 00:00:00', 160, 87, 58, 85, 'F', '三重県', '2019年 -',
        '出道作品(2019年03月 09日)', 'https://example.invalid/social',
        'https://example.invalid/official', '2023-11-23 17:53:16', 8
      );
      INSERT INTO Names(Alias, Name, Roma)
        VALUES ('涼森れむ', '涼森れむ', 'Suzumori Remu');
    ''');
  } finally {
    database.dispose();
  }
}

void _addManyActors(String dataPath, int count) {
  final tasks = sqlite3.open('$dataPath${Platform.pathSeparator}mdc_ng.db');
  final profiles = sqlite3.open('$dataPath${Platform.pathSeparator}Actress.db');
  try {
    tasks.execute('BEGIN');
    profiles.execute('BEGIN');
    for (var id = 3; id <= count + 2; id++) {
      final name = '测试演员$id';
      tasks.execute('''
        INSERT INTO actress_task(id, name, status, stage, emby_id)
        VALUES (?, ?, 2, 1000, ?)
      ''', [id, name, 'emby-$id']);
      profiles.execute(
          'INSERT INTO Info(Name, Href) VALUES (?, ?)', [name, 'actress-$id']);
    }
    tasks.execute('COMMIT');
    profiles.execute('COMMIT');
  } finally {
    tasks.dispose();
    profiles.dispose();
  }
}

void _expect(bool condition, String message) {
  if (!condition) throw StateError(message);
}
