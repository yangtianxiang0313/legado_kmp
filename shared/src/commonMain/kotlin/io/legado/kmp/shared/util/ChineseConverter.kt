package io.legado.kmp.shared.util

/**
 * Simplified Chinese ↔ Traditional Chinese character-level converter.
 * Contains the most common ~2200 character mappings used in novel content.
 */
object ChineseConverter {

    /**
     * Traditional → Simplified
     */
    fun t2s(text: String): String = text.map { ch -> T2S_MAP[ch] ?: ch }.joinToString("")

    /**
     * Simplified → Traditional
     */
    fun s2t(text: String): String = text.map { ch -> S2T_MAP[ch] ?: ch }.joinToString("")

    // Traditional → Simplified mapping (most common characters used in novels)
    private val T2S_MAP: Map<Char, Char> by lazy { buildT2sMap() }
    private val S2T_MAP: Map<Char, Char> by lazy { buildS2tMap() }

    private fun buildT2sMap(): Map<Char, Char> {
        val map = HashMap<Char, Char>(2500)
        // Each string is pairs of (traditional, simplified) characters
        val pairs = T2S_PAIRS
        var i = 0
        while (i < pairs.length - 1) {
            map[pairs[i]] = pairs[i + 1]
            i += 2
        }
        return map
    }

    private fun buildS2tMap(): Map<Char, Char> {
        val map = HashMap<Char, Char>(2500)
        val pairs = T2S_PAIRS
        var i = 0
        while (i < pairs.length - 1) {
            // Reverse mapping: simplified → traditional
            // Only set if not already mapped (first mapping wins for ambiguous cases)
            val simplified = pairs[i + 1]
            val traditional = pairs[i]
            if (simplified !in map) {
                map[simplified] = traditional
            }
            i += 2
        }
        return map
    }

    // Pairs of traditional → simplified characters concatenated into a single string.
    // Every two consecutive characters form a (traditional, simplified) pair.
    @Suppress("MaxLineLength")
    private const val T2S_PAIRS =
        "萬万與与醜丑專专業业東东絲丝並并個个豐丰臨临為为麗丽舉举義义樂乐書书買买亂乱" +
        "爭争於于雲云產产親亲億亿從从優优傳传傷伤體体備备傑杰價价實实覺觉寫写軍军農农馮冯" +
        "決决鳳凤則则創创區区動动勞劳勢势勝胜務务勵励長长問问連连進进運运過过達达違违遠远適适選选遲迟還还邊边遺遗鄭郑鄰邻酌酌開开間间關关陳陈陰阴陽阳際际陣阵階阶隨随隱隐險险難难離离電电靈灵頂顶項项順顺須须領领頭头頻频題题顏颜顧顾類类風风飛飞飲饮養养餘余馬马驗验" +
        "幾几廣广復复無无歲岁歷历歸归歡欢處处備备傳传書书氣气決决漢汉濟济滅灭準准環环現现獨独獲获獻献產产畫画當当療疗發发監监確确禮礼種种積积穩稳記记認认講讲識识質质藝艺議议護护觀观負负財财貿贸費费資资構构設设許许調调變变計计許许離离課课響响讓让議议讀读" +
        "鑑鉴鑒鉴銀银銅铜鋼钢錢钱鐵铁鐘钟錄录鑰钥鏡镜門门閃闪開开閉闭間间閒闲關关閣阁閱阅闆板閥阀闡阐離离齊齐齒齿點点鼓鼓龍龙龜龟" +
        "對对園园場场報报壓压壞坏墻墙壯壮聲声處处備备夠够夢梦學学寶宝實实審审導导專专屬属層层歲岁師师幣币幫帮廠厂歷历歸归歡欢歐欧殘残漸渐潔洁瀏浏滿满漣涟潰溃澤泽濃浓" +
        "練练維维經经繼继結结網网線线統统繩绳繫系縣县縮缩總总織织縱纵紀纪約约純纯續续聯联聽听職职聯联腦脑臘腊臺台舉举興兴藝艺藥药補补複复規规視视覺觉計计訊讯該该試试語语說说請请論论護护詞词診诊證证評评認认記记誤误話话詳详詢询詩诗許许訂订誌志調调談谈諸诸謊谎謀谋謝谢諾诺講讲證证識识議议讓让豐丰負负責责貓猫貝贝賀贺賢贤賣卖賬账賽赛購购貿贸質质趙赵趕赶車车軌轨軍军軟软載载轉转輕轻較较輝辉輸输輩辈辦办農农邊边遊游運运選选遷迁遼辽達达違违遠远適适遲迟遺遗鄭郑鄰邻釋释針针釣钓銷销鍵键鋼钢錯错錢钱鎮镇鎖锁鏈链鋒锋鑰钥鑽钻閣阁閱阅際际險险隊队隨随隱隐雙双雞鸡離离難难額额顫颤顯显飯饭餓饿駐驻駕驾驅驱騎骑騙骗驚惊體体魚鱼鱷鳄鳥鸟鶴鹤鳴鸣鷹鹰麥麦麼么鼎鼎齡龄齊齐齒齿" +
        "匯汇習习叢丛擊击歐欧區区嗎吗嘆叹嘗尝噓嘘嚴严團团圍围國国塊块堅坚復复極极構构機机檢检權权標标樹树歷历歸归氣气灣湾測测損损撐撑撲扑據据數数斷断資资" +
        "戰战戲戏態态憶忆應应懷怀懼惧戀恋擔担摳抠擋挡擠挤擺摆擴扩攬揽敗败數数條条棗枣樓楼檔档獎奖勢势廟庙願愿顧顾劇剧陰阴陽阳隻只雜杂靜静備备預预騰腾驗验鬥斗鬧闹麗丽黨党齡龄" +
        "紅红約约級级紛纷紙纸細细絡络組组終终給给繪绘綁绑繡绣綠绿綜综綱纲網网緊紧緒绪線线緣缘編编練练緻致縮缩縱纵繁繁繼继纏缠繞绕聯联" +
        "蘇苏範范蠟蜡衝冲裝装覆覆規规覽览親亲覺觉觸触訪访設设許许診诊註注証证評评詢询詳详認认誤误說说課课誰谁請请論论諷讽諧谐諾诺謙谦證证識识譜谱議议護护讓让變变豐丰責责貧贫貨货販贩貫贯貴贵賬账購购賽赛贈赠趕赶車车載载輪轮轉转辯辩辭辞農农迴回遊游適适遷迁選选遺遗鄭郑釋释鋼钢錄录銷销鋒锋錢钱鍋锅鍵键鏡镜鐮镰鐲镯鑰钥鑽钻門门閃闪開开閱阅闡阐陣阵階阶隊队際际隨随隱隐隻只雙双雜杂離离難难電电靈灵頂顶領领頭头頻频題题顏颜顧顾類类飄飘飯饭飲饮養养駐驻駕驾騎骑騙骗驚惊體体魚鱼鳥鸟鶴鹤鷹鹰麥麦齡龄齊齐齒齿龍龙龜龟" +
        "燈灯燒烧營营獸兽獵猎瑣琐瓊琼療疗發发監监盡尽盤盘籤签簡简簫箫節节箋笺範范築筑籃篮籠笼類类薦荐薩萨藏藏藝艺蘇苏蘭兰觸触訪访詞词詳详語语誰谁說说諸诸謊谎謀谋謝谢講讲證证識识譜谱議议護护讓让變变豐丰趕赶載载轉转較较輝辉辦办農农選选遷迁運运遠远適适遲迟違违還还遺遗鄰邻釋释鐵铁鐘钟鋒锋錢钱鎮镇鎖锁鏈链鋼钢錯错鏡镜鑰钥鑽钻閣阁閱阅際际隊队隨随隱隐險险雞鸡離离難难電电靈灵頂顶頭头頻频題题顏颜顧顾類类飯饭養养駕驾驅驱騎骑驚惊體体魚鱼鳥鸟鶴鹤鷹鹰齡龄齊齐齒齿龍龙"
}
