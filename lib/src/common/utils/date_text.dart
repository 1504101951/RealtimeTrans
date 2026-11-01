/// value 为本地时间；返回 yyyy-MM-dd。
String dateText(DateTime value) =>
    '${value.year}-${_pad(value.month)}-${_pad(value.day)}';

/// value 为本地时间；返回 yyyy-MM-dd HH:mm。
String dateTimeText(DateTime value) =>
    '${dateText(value)} ${_pad(value.hour)}:${_pad(value.minute)}';

/// value 为月、日、时或分；返回补零到两位的文本。
String _pad(int value) => value.toString().padLeft(2, '0');
