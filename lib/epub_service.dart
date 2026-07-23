import 'dart:io';
import 'package:epubx/epubx.dart';

/// Service class to handle EPUB extraction and parsing
class EpubService {
  
  /// Loads an EPUB file from the device storage and parses it
  static Future<EpubBook?> loadEpub(String filePath) async {
    try {
      // 1. Read the file as bytes
      File epubFile = File(filePath);
      List<int> bytes = await epubFile.readAsBytes();
      
      // 2. Parse the bytes into an EpubBook object
      EpubBook epubBook = await EpubReader.readBook(bytes);
      
      return epubBook;
    } catch (e) {
      print("Error loading EPUB: $e");
      return null;
    }
  }

  /// Extracts the HTML content from a specific chapter
  static String getChapterHtml(EpubBook epubBook, int chapterIndex) {
    if (epubBook.Chapters == null || epubBook.Chapters!.isEmpty) {
      return "<p>No chapters found in this book.</p>";
    }

    // Ensure the index is within bounds
    if (chapterIndex < 0 || chapterIndex >= epubBook.Chapters!.length) {
      return "<p>Chapter out of bounds.</p>";
    }

    // Get the specific chapter
    EpubChapter chapter = epubBook.Chapters![chapterIndex];
    
    // Return the HTML string of the chapter
    // Note: We will inject our CSS into this HTML later in the WebView
    return chapter.HtmlContent ?? "<p>Empty chapter.</p>";
  }
}