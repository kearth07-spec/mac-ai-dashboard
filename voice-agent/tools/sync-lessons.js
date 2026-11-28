// リポジトリ直下の index.html のレッスンを、アプリ用の Sources/Orrery/LessonData.swift に書き出す。
// 使い方: node tools/sync-lessons.js （voice-agent フォルダで実行）
const fs = require("fs");
const path = require("path");
const src = fs.readFileSync(path.join(__dirname, "../../index.html"), "utf8");
const match = src.match(/const LESSONS = (\[[\s\S]*?\n\]);/);
if (!match) throw new Error("index.html に LESSONS が見つかりません");
const lessons = Function(`return ${match[1]}`)();
const q = (s) => JSON.stringify(s).replace(/\\u([0-9a-fA-F]{4})/g, "\\u{$1}");
let out = `import Foundation

/// 「Mac & AI 学習ダッシュボード」（リポジトリ直下の index.html）のレッスン。
/// index.html を編集したら tools/sync-lessons.js を実行して作り直す。
struct Lesson {
    let day: Int
    let tag: String
    let title: String
    let body: String
    let tips: [String]
    let shortcuts: [String]
}

enum Lessons {
    static let all: [Lesson] = [
`;
for (const l of lessons) {
  out += `        Lesson(day: ${l.day}, tag: ${q(l.tag)},\n               title: ${q(l.title)},\n               body: ${q(l.body)},\n               tips: [${l.tips.map(q).join(", ")}],\n               shortcuts: [${l.shortcuts.map(q).join(", ")}]),\n`;
}
out += `    ]
}
`;
fs.writeFileSync(path.join(__dirname, "../Sources/Orrery/LessonData.swift"), out);
console.log(`${lessons.length} 件のレッスンを書き出しました`);
