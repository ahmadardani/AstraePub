import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:epubx/epubx.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';
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

  bool _isTranslating = false;
  TranslateLanguage _sourceLanguage = TranslateLanguage.english;
  TranslateLanguage _targetLanguage = TranslateLanguage.indonesian;

  @override
  void initState() {
    super.initState();
    _webViewController = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFFFAFAFA));
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

    String rawHtml = EpubService.getChapterHtml(_currentBook!, chapterIndex);

    // Fix rendering of images embedded in the EPUB
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

    // HTML wrapped with horizontal-reading CSS
    String wrappedHtml = '''
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="UTF-8">
      <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
      <style>
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
      </style>
    </head>
    <body>
      
      <!-- Original book content -->
      <div id="content-body">
        $rawHtml
      </div>

    </body>
    </html>
    ''';

    _webViewController.loadHtmlString(wrappedHtml);
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

    final rawHtml =
        EpubService.getChapterHtml(_currentBook!, _currentChapterIndex);
    final plainText = _extractPlainText(rawHtml);

    final modelManager = OnDeviceTranslatorModelManager();
    final translator = OnDeviceTranslator(
      sourceLanguage: _sourceLanguage,
      targetLanguage: _targetLanguage,
    );

    try {
      // Download the language models if they aren't already on the device.
      await modelManager.downloadModel(_sourceLanguage.bcpCode);
      await modelManager.downloadModel(_targetLanguage.bcpCode);

      final translated = await translator.translateText(plainText);

      if (!mounted) return;
      _showTranslatedText(translated);
    } catch (e) {
      debugPrint('Translation failed: $e');
      if (mounted) {
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

  /// Shows a small dialog letting the user choose the source and target
  /// language for translation.
  Future<(TranslateLanguage, TranslateLanguage)?> _pickLanguages() async {
    const languageOptions = <String, TranslateLanguage>{
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
                    items: languageOptions.entries
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
                    items: languageOptions.entries
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
          // Translate button
          if (_currentBook != null)
            IconButton(
              icon: _isTranslating
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.g_translate, color: Colors.blueAccent),
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