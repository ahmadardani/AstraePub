import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:epubx/epubx.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';
import 'package:url_launcher/url_launcher.dart';
import 'epub_service.dart';

void main() {
  runApp(const AstraePubApp());
}

class AstraePubApp extends StatelessWidget {
  const AstraePubApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AstraePub',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF333333),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFFAFAFA),
      ),
      home: const ReaderScreen(),
    );
  }
}

class ReaderScreen extends StatefulWidget {
  const ReaderScreen({super.key});

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen> {
  EpubBook? _currentBook;
  String _appBarTitle = 'Reading';
  bool _isLoading = false;
  int _currentChapterIndex = 0;

  late final WebViewController _webViewController;

  HttpServer? _previewServer;

  bool _isTranslating = false;
  TranslateLanguage _sourceLanguage = TranslateLanguage.english;
  TranslateLanguage _targetLanguage = TranslateLanguage.indonesian;
  final ValueNotifier<String> _translationStatus = ValueNotifier<String>('');

  static const Map<String, TranslateLanguage> _languageOptions = {
    'English': TranslateLanguage.english,
    'Indonesian': TranslateLanguage.indonesian,
    'Spanish': TranslateLanguage.spanish,
    'French': TranslateLanguage.french,
    'German': TranslateLanguage.german,
    'Japanese': TranslateLanguage.japanese,
    'Korean': TranslateLanguage.korean,
    'Chinese': TranslateLanguage.chinese,
    'Arabic': TranslateLanguage.arabic,
    'Russian': TranslateLanguage.russian,
    'Portuguese': TranslateLanguage.portuguese,
    'Italian': TranslateLanguage.italian,
    'Hindi': TranslateLanguage.hindi,
    'Vietnamese': TranslateLanguage.vietnamese,
    'Thai': TranslateLanguage.thai,
  };

  /// Human-readable name for a [TranslateLanguage], used in status messages.
  String _languageLabel(TranslateLanguage language) {
    return _languageOptions.entries
        .firstWhere((e) => e.value == language,
            orElse: () => MapEntry(language.name, language))
        .key;
  }

  @override
  void initState() {
    super.initState();
    _webViewController = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFFFAFAFA));
  }

  @override
  void dispose() {
    _translationStatus.dispose();
    _previewServer?.close(force: true);
    super.dispose();
  }

  Future<void> _pickAndLoadEpub() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['epub'],
    );

    if (result != null && result.files.single.path != null) {
      setState(() {
        _isLoading = true;
      });

      String filePath = result.files.single.path!;
      EpubBook? parsedBook = await EpubService.loadEpub(filePath);

      if (parsedBook != null) {
        setState(() {
          _currentBook = parsedBook;
          _appBarTitle = parsedBook.Title ?? 'Unknown Title';
          _currentChapterIndex = 0;
        });

        _loadChapterToWebView(_currentChapterIndex);

        setState(() {
          _isLoading = false;
        });
      } else {
        setState(() { _isLoading = false; });
        debugPrint('Failed to parse the EPUB file.');
      }
    }
  }

  void _loadChapterToWebView(int chapterIndex) {
    if (_currentBook == null) return;

    final rawHtml = _getChapterHtmlWithImages(chapterIndex);
    final wrappedHtml =
        _wrapHtml(bodyContent: '<div id="content-body">$rawHtml</div>');

    _webViewController.loadHtmlString(wrappedHtml);
  }

  /// Returns a chapter's HTML with embedded EPUB images converted to inline
  /// base64 data URIs, so it renders correctly whether it's loaded into the
  /// in-app WebView or served to an external browser.
  String _getChapterHtmlWithImages(int chapterIndex) {
    String rawHtml = EpubService.getChapterHtml(_currentBook!, chapterIndex);

    if (_currentBook!.Content?.Images != null) {
      _currentBook!.Content!.Images!.forEach((key, epubImageFile) {
        if (epubImageFile.Content != null) {
          String base64Image = base64Encode(epubImageFile.Content!);
          String mimeType = 'image/jpeg';
          if (key.toLowerCase().endsWith('.png')) mimeType = 'image/png';
          if (key.toLowerCase().endsWith('.gif')) mimeType = 'image/gif';

          String dataUri = 'data:$mimeType;base64,$base64Image';

          rawHtml = rawHtml.replaceAll(key, dataUri);
          String fileName = key.split('/').last;
          rawHtml = rawHtml.replaceAll(fileName, dataUri);
        }
      });
    }

    return rawHtml;
  }

  // Shared horizontal-reading CSS used by both the in-app WebView and the
  // pages served to the external browser preview.
  static const String _readingCss = '''
    * {
      writing-mode: horizontal-tb !important;
      -webkit-writing-mode: horizontal-tb !important;
      text-orientation: mixed !important;
      direction: ltr !important;
      line-height: 1.8 !important;
    }
    html, body {
      margin: 0 !important;
      padding: 15px !important;
      background-color: #FAFAFA;
      color: #333333;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
      overflow-x: hidden;
    }
    img {
      max-width: 100% !important;
      height: auto !important;
      display: block;
      margin: 15px auto !important;
    }
  ''';

  /// Wraps arbitrary body content with the shared reading CSS.
  String _wrapHtml({required String bodyContent}) {
    return '''
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="UTF-8">
      <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
      <style>
        $_readingCss
      </style>
    </head>
    <body>
      $bodyContent
    </body>
    </html>
    ''';
  }

  /// Strips HTML tags and decodes the handful of entities that show up in
  /// EPUB chapter markup, so the on-device translator receives plain text
  /// instead of raw markup.
  String _extractPlainText(String html) {
    String text = html.replaceAll(RegExp(r'<[^>]*>'), ' ');
    text = text
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'");
    return text.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  /// Lets the user pick source/target languages, then translates the
  /// current chapter fully on-device via Google ML Kit — no internet or
  /// WebView JavaScript is required once the language models are downloaded.
  Future<void> _translateCurrentPage() async {
    if (_currentBook == null) return;

    final picked = await _pickLanguages();
    if (picked == null) return;

    setState(() {
      _sourceLanguage = picked.$1;
      _targetLanguage = picked.$2;
      _isTranslating = true;
    });

    _translationStatus.value = 'Preparing…';
    _showTranslatingDialog();

    final rawHtml =
        EpubService.getChapterHtml(_currentBook!, _currentChapterIndex);
    final plainText = _extractPlainText(rawHtml);

    final modelManager = OnDeviceTranslatorModelManager();
    final translator = OnDeviceTranslator(
      sourceLanguage: _sourceLanguage,
      targetLanguage: _targetLanguage,
    );

    try {
      // Only download a language pack if it isn't already on the device —
      // this is what makes every translation after the first one instant.
      final needsSource =
          !await modelManager.isModelDownloaded(_sourceLanguage.bcpCode);
      if (needsSource) {
        _translationStatus.value =
            'Downloading ${_languageLabel(_sourceLanguage)} language pack…';
        await modelManager.downloadModel(_sourceLanguage.bcpCode);
      }

      final needsTarget =
          !await modelManager.isModelDownloaded(_targetLanguage.bcpCode);
      if (needsTarget) {
        _translationStatus.value =
            'Downloading ${_languageLabel(_targetLanguage)} language pack…';
        await modelManager.downloadModel(_targetLanguage.bcpCode);
      }

      _translationStatus.value = 'Translating chapter…';
      final translated = await translator.translateText(plainText);

      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop(); // close loading dialog
      _showTranslatedText(translated);
    } catch (e) {
      debugPrint('Translation failed: $e');
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop(); // close loading dialog
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Translation failed. Please check your connection and try again.'),
          ),
        );
      }
    } finally {
      await translator.close();
      if (mounted) setState(() => _isTranslating = false);
    }
  }

  /// Blocking dialog shown while the language pack downloads and/or the
  /// chapter is being translated, with a live-updating status line so it's
  /// clear the app is working and not just stuck buffering.
  void _showTranslatingDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return PopScope(
          canPop: false,
          child: AlertDialog(
            content: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: ValueListenableBuilder<String>(
                    valueListenable: _translationStatus,
                    builder: (context, value, _) => Text(value),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Shows a small dialog letting the user choose the source and target
  /// language for translation.
  Future<(TranslateLanguage, TranslateLanguage)?> _pickLanguages() async {
    TranslateLanguage source = _sourceLanguage;
    TranslateLanguage target = _targetLanguage;

    return showDialog<(TranslateLanguage, TranslateLanguage)>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('Translate Chapter'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DropdownButtonFormField<TranslateLanguage>(
                    value: source,
                    decoration: const InputDecoration(labelText: 'From'),
                    items: _languageOptions.entries
                        .map((e) => DropdownMenuItem(
                              value: e.value,
                              child: Text(e.key),
                            ))
                        .toList(),
                    onChanged: (value) {
                      if (value != null) setDialogState(() => source = value);
                    },
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<TranslateLanguage>(
                    value: target,
                    decoration: const InputDecoration(labelText: 'To'),
                    items: _languageOptions.entries
                        .map((e) => DropdownMenuItem(
                              value: e.value,
                              child: Text(e.key),
                            ))
                        .toList(),
                    onChanged: (value) {
                      if (value != null) setDialogState(() => target = value);
                    },
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, (source, target)),
                  child: const Text('Translate'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  /// Displays the translated chapter text in a scrollable bottom sheet.
  void _showTranslatedText(String translated) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return DraggableScrollableSheet(
          initialChildSize: 0.75,
          minChildSize: 0.4,
          maxChildSize: 0.95,
          expand: false,
          builder: (context, scrollController) {
            return Column(
              children: [
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    'Translated Text',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: SingleChildScrollView(
                    controller: scrollController,
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      translated,
                      style: const TextStyle(fontSize: 15, height: 1.6),
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  /// Starts (or reuses) a local HTTP server bound to 127.0.0.1 only, then
  /// opens the current chapter in the device's external browser. Pages are
  /// fully navigable in the browser via real links — no need to come back
  /// to the app to change chapters.
  Future<void> _openBrowserPreview() async {
    if (_currentBook == null) return;

    try {
      if (_previewServer == null) {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen(_handlePreviewRequest);
        _previewServer = server;
      }

      final port = _previewServer!.port;
      final uri =
          Uri.parse('http://127.0.0.1:$port/chapter/$_currentChapterIndex');
      final launched =
          await launchUrl(uri, mode: LaunchMode.externalApplication);

      if (!launched && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open the browser.')),
        );
      }
    } catch (e) {
      debugPrint('Failed to start browser preview: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to start browser preview.')),
        );
      }
    }
  }

  /// Routes incoming requests from the local preview server: "/" shows the
  /// chapter index, "/chapter/<n>" shows a specific chapter.
  void _handlePreviewRequest(HttpRequest request) async {
    final path = request.uri.path;
    String html;

    if (path == '/') {
      html = _buildIndexHtml();
    } else if (path.startsWith('/chapter/')) {
      final index = int.tryParse(path.substring('/chapter/'.length));
      final chapters = _currentBook?.Chapters;
      final isValid = index != null &&
          chapters != null &&
          index >= 0 &&
          index < chapters.length;

      if (isValid) {
        html = _buildChapterHtmlForServer(index);
      } else {
        request.response.statusCode = HttpStatus.notFound;
        html = _wrapHtml(bodyContent: '<p>Chapter not found.</p>');
      }
    } else {
      request.response.statusCode = HttpStatus.notFound;
      html = _wrapHtml(bodyContent: '<p>Not found.</p>');
    }

    request.response.headers.contentType = ContentType.html;
    request.response.write(html);
    await request.response.close();
  }

  /// Builds the chapter list landing page ("/") for the browser preview.
  String _buildIndexHtml() {
    final chapters = _currentBook?.Chapters ?? [];
    final bookTitle = _currentBook?.Title ?? 'Book';

    final items = StringBuffer();
    for (var i = 0; i < chapters.length; i++) {
      final chapterTitle = chapters[i].Title?.trim().isNotEmpty == true
          ? chapters[i].Title!
          : 'Chapter ${i + 1}';
      items.writeln(
        '<li><a href="/chapter/$i" '
        'style="display:block;padding:12px 0;text-decoration:none;'
        'color:#333;border-bottom:1px solid #eee;">$chapterTitle</a></li>',
      );
    }

    final body = '''
      <h2 style="margin-top:0;">$bookTitle</h2>
      <ul style="list-style:none;padding:0;margin:0;">
        $items
      </ul>
    ''';

    return _wrapHtml(bodyContent: body);
  }

  /// Builds a single chapter page for the browser preview, with real
  /// Prev/Next/Chapters links so the browser can navigate on its own.
  String _buildChapterHtmlForServer(int index) {
    final chapters = _currentBook!.Chapters!;
    final total = chapters.length;
    final rawHtml = _getChapterHtmlWithImages(index);

    final prevLink = index > 0
        ? '<a href="/chapter/${index - 1}" style="text-decoration:none;color:#333;">&larr; Prev</a>'
        : '<span style="color:#ccc;">&larr; Prev</span>';
    final nextLink = index < total - 1
        ? '<a href="/chapter/${index + 1}" style="text-decoration:none;color:#333;">Next &rarr;</a>'
        : '<span style="color:#ccc;">Next &rarr;</span>';

    final body = '''
      <div style="display:flex;justify-content:space-between;align-items:center;
                  padding-bottom:10px;border-bottom:1px solid #eee;
                  margin-bottom:15px;font-size:13px;">
        <a href="/" style="text-decoration:none;color:#333;">&#9776; Chapters</a>
        <span style="color:#999;">Chapter ${index + 1} of $total</span>
      </div>
      <div id="content-body">
        $rawHtml
      </div>
      <div style="display:flex;justify-content:space-between;padding-top:20px;
                  margin-top:20px;border-top:1px solid #eee;">
        $prevLink
        $nextLink
      </div>
    ''';

    return _wrapHtml(bodyContent: body);
  }

  /// Jumps directly to a given chapter index
  void _goToChapter(int index) {
    setState(() {
      _currentChapterIndex = index;
    });
    _loadChapterToWebView(index);
  }

  /// Shows a bottom sheet with the full chapter list so the user can jump
  /// straight to any chapter instead of only moving one at a time.
  void _showChapterList() {
    if (_currentBook == null || _currentBook!.Chapters == null) return;

    final chapters = _currentBook!.Chapters!;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return DraggableScrollableSheet(
          initialChildSize: 0.6,
          minChildSize: 0.3,
          maxChildSize: 0.9,
          expand: false,
          builder: (context, scrollController) {
            return Column(
              children: [
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    'Chapters',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: ListView.builder(
                    controller: scrollController,
                    itemCount: chapters.length,
                    itemBuilder: (context, index) {
                      final chapter = chapters[index];
                      final title = chapter.Title?.trim().isNotEmpty == true
                          ? chapter.Title!
                          : 'Chapter ${index + 1}';
                      final isSelected = index == _currentChapterIndex;

                      return ListTile(
                        title: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontWeight: isSelected ? FontWeight.w700 : FontWeight.w400,
                            color: isSelected ? Colors.blueAccent : Colors.black87,
                          ),
                        ),
                        trailing: isSelected
                            ? const Icon(Icons.check, color: Colors.blueAccent, size: 18)
                            : null,
                        onTap: () {
                          Navigator.pop(context);
                          _goToChapter(index);
                        },
                      );
                    },
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _appBarTitle,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        centerTitle: true,
        backgroundColor: Colors.white,
        elevation: 0,
        scrolledUnderElevation: 0,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1.0),
          child: Container(color: Colors.grey.shade300, height: 1.0),
        ),
        actions: [
          // Chapter navigation button
          if (_currentBook != null)
            IconButton(
              icon: const Icon(Icons.list, color: Colors.black87),
              tooltip: 'Chapter List',
              onPressed: _showChapterList,
            ),
          // Browser preview button
          if (_currentBook != null)
            IconButton(
              icon: const Icon(Icons.open_in_browser, color: Colors.black87),
              tooltip: 'Preview in Browser',
              onPressed: _openBrowserPreview,
            ),
          // Translate button
          if (_currentBook != null)
            IconButton(
              icon: const Icon(Icons.g_translate, color: Colors.blueAccent),
              tooltip: 'Translate Chapter',
              onPressed: _isTranslating ? null : _translateCurrentPage,
            ),
          // Open file button
          IconButton(
            icon: const Icon(Icons.folder_open, color: Colors.black87),
            tooltip: 'Open EPUB',
            onPressed: _pickAndLoadEpub,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _currentBook == null
              ? const Center(child: Text('Please open an EPUB file.'))
              : WebViewWidget(controller: _webViewController),
      
      bottomNavigationBar: _currentBook == null
          ? null
          : Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.white,
                border: Border(top: BorderSide(color: Colors.grey.shade300)),
              ),
              child: SafeArea(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    TextButton.icon(
                      onPressed: _currentChapterIndex > 0
                          ? () {
                              setState(() {
                                _currentChapterIndex--;
                              });
                              _loadChapterToWebView(_currentChapterIndex);
                            }
                          : null,
                      icon: const Icon(Icons.arrow_back_ios, size: 16),
                      label: const Text('Prev'),
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.black87,
                        disabledForegroundColor: Colors.grey,
                      ),
                    ),
                    GestureDetector(
                      onTap: _showChapterList,
                      child: Text(
                        'Chapter ${_currentChapterIndex + 1}',
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: Colors.black54,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: _currentChapterIndex < (_currentBook!.Chapters!.length - 1)
                          ? () {
                              setState(() {
                                _currentChapterIndex++;
                              });
                              _loadChapterToWebView(_currentChapterIndex);
                            }
                          : null,
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.black87,
                        disabledForegroundColor: Colors.grey,
                      ),
                      child: const Row(
                        children: [
                          Text('Next'),
                          SizedBox(width: 4),
                          Icon(Icons.arrow_forward_ios, size: 16),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}