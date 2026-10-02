# 使用 iLoader 安裝 SideStore + LiveContainer 實現 iOS 無限側載教學

[![Deploy with Vercel](https://vercel.com/button)](https://vercel.com/new/clone?repository-url=https://github.com/darrenintr/pure-bilibili-rethinking)

iOS 免費開發者帳號平時限制咗每部設備最多只能側載 **3 個 App**，而且每 7 日就要續簽一次。
透過 **iLoader** 安裝 **LiveContainer + SideStore 二合一版本**，你可以將多個 App 直接擺入 LiveContainer 入面運行，**完全唔佔用 3 個 App 嘅限額**，從而達到「無限側載」嘅效果！

---

## 🛠️ 準備工作

### 1. 電腦端準備
* **Windows 用戶**：必須去 Microsoft Store 或者 Apple 官方下載並安裝最新版 **iTunes**（唔需要額外下載 iCloud）。
* **Mac 用戶**：系統內置已支援，直接插線就得。
* **數據線**：準備一條高質量、連線穩定嘅傳輸線。

### 2. 手機端準備
* 一個平時用開嘅 **Apple ID / Apple Account**。
* 去 App Store 下載並安裝 **LocalDevVPN**（SideStore 必備嘅本機模擬 VPN）。

---

## 📥 第一步：下載並運行 iLoader

1. 前往官方 GitHub 儲存庫下載最新版本嘅 **iLoader**。
2. 打開 iLoader。如果介面係英文，可以拉落去語言選項（Language）將其切換為 **中文**。



---

## 🔐 第二步：登入 Apple ID 與連接設備

1. 喺 iLoader 畫面輸入你嘅 **Apple ID 帳號（電郵）** 同 **密碼**，然後點擊登入。
2. 如果你嘅 Apple ID 開啟咗雙重認證（2FA），iLoader 會彈出視窗提示，直接喺電腦輸入你手機收到嘅 **6 位數驗證碼** 即可。
3. 用傳輸線將 iPhone/iPad 連接電腦。手機如果彈出「要信任此電腦嗎？」，請點擊 **信任** 並輸入鎖屏密碼。
4. 喺 iLoader 點擊 **刷新設備**，選中你部 iOS 設備。



---

## 🚀 第三步：一鍵安裝 LiveContainer + SideStore 二合一版

iLoader 最強大嘅地方，就係佢提供咗一個「二合一」嘅安裝選項：

1. 喺 iLoader 嘅安裝選項中，搵到並點擊 **LiveContainer + SideStore (穩定版)**。
2. 唔好選單獨嘅 SideStore！呢個二合一版本會將 SideStore 嘅功能直接嵌入到 LiveContainer 入面，手機畫面上只會出現一個 LiveContainer 嘅 Icon，但功能最齊全！
3. 點擊後，iLoader 會自動下載並幫你將呢個工具安裝到手機，同時會**自動幫你配置好 Pairing File（配對文件）**，唔需要手動匯入。



---

## 📱 第四步：手機端啟用與信任證書

安裝完成後，手機會多左個 LiveContainer 嘅圖標，但呢個時候仲未開啟得，需要做以下設定：

1. **信任開發者App**：
   * 喺手機打開 **設定 (Settings) -> 通用 (General) -> VPN 與設備管理 (VPN & Device Management)**。
   * 喺「開發者 APP」下方點擊你剛才登入嘅 Apple ID。
   * 點擊 **信任 [你嘅 Apple ID]** 並確認。
2. **開啟開發者模式 (iOS 16 或以上系統必做)**：
   * 喺手機打開 **設定 -> 隱私與安全性 (Privacy & Security)**。
   * 拉到最底搵到 **開發者模式 (Developer Mode)**，將佢打開。
   * 按照提示重新啟動手機，重啟後彈出視窗點擊 **開啟** 並輸入密碼。



---

## 🔧 第五步：配置 LiveContainer 與 SideStore 聯動

1. 打開手機上嘅 **LocalDevVPN**，點擊 **Connect** 連接本機 VPN（側載刷新必備，全程保持開啟）。
2. 打開 **LiveContainer**。你會見到主介面左上角多咗個 **SideStore 嘅圖標**。
3. 點擊左上角嘅 SideStore 圖標（首次進入如果閃退，重新入一次即可）。
4. 進入內置嘅 SideStore 後，切換到 **My Apps** 標籤頁，點擊 **Refresh All** 或者 SideStore 側邊嘅 **7 DAYS** 按鈕。
5. 系統會要求你再次輸入相同嘅 **Apple ID 同密碼** 進行登入續簽。成功後會顯示剩餘 7 天。
6. 點擊左上角退出按鈕，返去 LiveContainer 主介面。
7. 進入 LiveContainer 嘅 **設定 (Settings)** 頁面，點擊 **從 SideStore 導入證書 (Import Certificate From SideStore)**，彈出提示點擊 **好 (OK)**。
8. 點擊下方嘅 **免 JIT 模式診斷**，只要冇出現紅字，就代表大功告成！



---

## 🎉 第六步：開始無限側載 App！

依家你可以盡情安裝 IPA 檔啦：
1. 下載你想側載嘅 App `.ipa` 檔案到手機。
2. 打開 LiveContainer，點擊左上角嘅 **「+」號**。
3. 選擇你下載好嘅 `.ipa` 檔案。
4. 該 App 就會成功安裝喺 LiveContainer 入面！
5. **注意**：喺 LiveContainer 入面運行嘅 App **完全唔會佔用** Apple 官方限制嘅 3 個 App 名額，你想裝幾多個就裝幾多個！

### 💡 溫馨提示
* 側載嘅 App 有 7 日有效期限制。
* 只要每 7 日之內，確保手機連住 Wi-Fi 並開啟 **LocalDevVPN**，打開 LiveContainer 內置嘅 SideStore 點擊刷新，就可以實現無線自動續簽，以後都唔需要再插電腦！
