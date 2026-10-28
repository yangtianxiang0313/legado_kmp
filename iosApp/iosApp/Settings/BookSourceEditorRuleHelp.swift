// Offline ruleHelp.md from Legado 5f5d31404af9957684703747ecee2b91e7161f1d (GPL-3.0).
// Converted with marked 15.0.12; examples are documentation, never executable page scripts.
enum BookSourceEditorRuleHelp {
    static let html = #"""
        <!doctype html>
        <html lang="zh-CN"><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
        <style>
        :root { color-scheme: light dark; }
        body { margin: 12px; font-family: -apple-system, "PingFang SC", sans-serif; font-size: 14px; line-height: 1.5; overflow-wrap: anywhere; }
        h1 { font-size: 28px; }
        code, pre { font-family: ui-monospace, "PingFang SC", monospace; }
        pre { white-space: pre-wrap; }
        ul { padding-left: 24px; }
        blockquote { margin-inline: 16px 0; }
        a { color: inherit; }
        </style></head><body>
        <h1>源规则帮助</h1>
        <ul>
        <li><a href="https://mgz0227.github.io/The-tutorial-of-Legado/">阅读3.0(Legado)规则说明</a></li>
        <li><a href="https://mgz0227.github.io/The-tutorial-of-Legado/Rule/source.html">书源帮助文档</a></li>
        <li><a href="https://mgz0227.github.io/The-tutorial-of-Legado/Rule/rss.html">订阅源帮助文档</a></li>
        <li>辅助键盘❓中可插入URL参数模板,打开帮助,js教程,正则教程,选择文件</li>
        <li>规则标志, {{......}}内使用规则必须有明显的规则标志,没有规则标志当作js执行</li>
        </ul>
        <pre><code>@@ 默认规则,直接写时可以省略@@
        @XPath: xpath规则,直接写时以//开头可省略@XPath
        @Json: json规则,直接写时以$.开头可省略@Json
        : regex规则,不可省略,只可以用在书籍列表和目录列表
        </code></pre>
        <ul>
        <li>jsLib<blockquote>
        <p>注入JavaScript到RhinoJs引擎中，支持两种格式，可实现<a href="https://github.com/gedoor/legado/wiki/JavaScript%E5%87%BD%E6%95%B0%E5%85%B1%E7%94%A8">函数共用</a></p>
        </blockquote>
        </li>
        </ul>
        <blockquote>
        <p><code>JavaScript Code</code> 直接填写JavaScript片段<br><code>{&quot;example&quot;:&quot;https://www.example.com/js/example.js&quot;, ...}</code> 自动复用已经下载的js文件</p>
        </blockquote>
        <blockquote>
        <p>注意此处定义的函数可能会被多个线程同时调用，在函数里的全局变量内容将会共享使用，对其进行修改可能会出现竞争问题
        函数内不可声明全局变量，函数外的全局变量不可再赋值，否则会抛出 <code>无法修改密封对象的属性</code> 异常</p>
        </blockquote>
        <ul>
        <li>并发率<blockquote>
        <p>并发限制，单位ms，可填写两种格式</p>
        </blockquote>
        </li>
        </ul>
        <blockquote>
        <p><code>1000</code> 访问间隔1s<br><code>20/60000</code> 60s内访问次数20  </p>
        </blockquote>
        <ul>
        <li>书源类型: 文件<blockquote>
        <p>对于类似知轩藏书提供文件整合下载的网站，可以在书源详情的下载URL规则获取文件链接</p>
        </blockquote>
        </li>
        </ul>
        <blockquote>
        <p>通过截取下载链接或文件响应头头获取文件信息，获取失败会自动拼接<code>书名</code> <code>作者</code>和下载链接的<code>UrlOption</code>的<code>type</code>字段</p>
        </blockquote>
        <blockquote>
        <p>压缩文件解压缓存会在下次启动后自动清理，不会占用额外空间  </p>
        </blockquote>
        <ul>
        <li><p>CookieJar</p>
        <blockquote>
        <p>启用后会自动保存每次返回头中的Set-Cookie中的值，适用于验证码图片一类需要session的网站</p>
        </blockquote>
        </li>
        <li><p>登录UI</p>
        <blockquote>
        <p>不使用内置webView登录网站，需要使用<code>登录URL</code>规则实现登录逻辑，可使用<code>登录检查JS</code>检查登录结果<br>版本20221113重要更改：按钮支持调用<code>登录URL</code>规则里面的函数，必须实现<code>login</code>函数</p>
        </blockquote>
        </li>
        </ul>
        <pre><code>规则填写示范
        [
            {
                &quot;name&quot;: &quot;telephone&quot;,
                &quot;type&quot;: &quot;text&quot;
            },
            {
                &quot;name&quot;: &quot;password&quot;,
                &quot;type&quot;: &quot;password&quot;
            },
            {
                &quot;name&quot;: &quot;注册&quot;,
                &quot;type&quot;: &quot;button&quot;,
                &quot;action&quot;: &quot;http://www.yooike.com/xiaoshuo/#/register?title=%E6%B3%A8%E5%86%8C&quot;
            },
            {
                &quot;name&quot;: &quot;获取验证码&quot;,
                &quot;type&quot;: &quot;button&quot;,
                &quot;action&quot;: &quot;getVerificationCode()&quot;,
                &quot;style&quot;: {
                    &quot;layout_flexGrow&quot;: 0,
                    &quot;layout_flexShrink&quot;: 1,
                    &quot;layout_alignSelf&quot;: &quot;auto&quot;,
                    &quot;layout_flexBasisPercent&quot;: -1,
                    &quot;layout_wrapBefore&quot;: false
                }
            }
        ]
        </code></pre>
        <ul>
        <li>登录URL<blockquote>
        <p>可填写登录链接或者实现登录UI的登录逻辑的JavaScript</p>
        </blockquote>
        </li>
        </ul>
        <pre><code>示范填写
        function login() {
            java.log(&quot;模拟登录请求&quot;);
            java.log(source.getLoginInfoMap());
        }
        function getVerificationCode() {
            java.log(&quot;登录UI按钮：获取到手机号码&quot;+result.get(&quot;telephone&quot;))
        }

        登录按钮函数获取登录信息
        result.get(&quot;telephone&quot;)
        login函数获取登录信息
        source.getLoginInfo()
        source.getLoginInfoMap().get(&quot;telephone&quot;)
        source登录相关方法,可在js内通过source.调用,可以参考阿里云语音登录
        login()
        getHeaderMap(hasLoginHeader: Boolean = false)
        getLoginHeader(): String?
        getLoginHeaderMap(): Map&lt;String, String&gt;?
        putLoginHeader(header: String)
        removeLoginHeader()
        setVariable(variable: String?)
        getVariable(): String?
        AnalyzeUrl相关函数,js中通过java.调用
        initUrl() //重新解析url,可以用于登录检测js登录后重新解析url重新访问
        getHeaderMap().putAll(source.getHeaderMap(true)) //重新设置登录头
        getStrResponse( jsStr: String? = null, sourceRegex: String? = null) //返回访问结果,文本类型,书源内部重新登录后可调用此方法重新返回结果
        getResponse(): Response //返回访问结果,网络朗读引擎采用的是这个,调用登录后在调用这方法可以重新访问,参考阿里云登录检测
        </code></pre>
        <ul>
        <li>发现url格式</li>
        </ul>
        <pre><code class="language-json">[
          {
            &quot;title&quot;: &quot;xxx&quot;,
            &quot;url&quot;: &quot;&quot;,
            &quot;style&quot;: {
              &quot;layout_flexGrow&quot;: 0,
              &quot;layout_flexShrink&quot;: 1,
              &quot;layout_alignSelf&quot;: &quot;auto&quot;,
              &quot;layout_flexBasisPercent&quot;: -1,
              &quot;layout_wrapBefore&quot;: false
            }
          }
        ]
        </code></pre>
        <ul>
        <li>请求头,支持http代理,socks4 socks5代理设置<blockquote>
        <p>注意请求头的key是区分大小写的<br>正确格式 User-Agent Referer<br>错误格式 user-agent referer</p>
        </blockquote>
        </li>
        </ul>
        <pre><code>socks5代理
        {
          &quot;proxy&quot;:&quot;socks5://127.0.0.1:1080&quot;
        }
        不支持需要验证的socks代理
        http代理
        {
          &quot;proxy&quot;:&quot;http://127.0.0.1:1080&quot;
        }
        支持http代理服务器验证
        {
          &quot;proxy&quot;:&quot;http://127.0.0.1:1080@用户名@密码&quot;
        }
        注意:这些请求头是无意义的,会被忽略掉
        </code></pre>
        <ul>
        <li>url添加js参数,解析url时执行,可在访问url时处理url,例</li>
        </ul>
        <pre><code>https://www.baidu.com,{&quot;js&quot;:&quot;java.headerMap.put(&#39;xxx&#39;, &#39;yyy&#39;)&quot;}
        https://www.baidu.com,{&quot;js&quot;:&quot;java.url=java.url+&#39;yyyy&#39;&quot;}
        </code></pre>
        <ul>
        <li>增加js方法，用于重定向拦截<ul>
        <li><code>java.get(urlStr: String, headers: Map&lt;String, String&gt;)</code></li>
        <li><code>java.post(urlStr: String, body: String, headers: Map&lt;String, String&gt;)</code></li>
        </ul>
        </li>
        <li>对于搜索重定向的源，可以使用此方法获得重定向后的url</li>
        </ul>
        <pre><code>(()=&gt;{
          if(page==1){
            let url=&#39;https://www.yooread.net/e/search/index.php,&#39;+JSON.stringify({
            &quot;method&quot;:&quot;POST&quot;,
            &quot;body&quot;:&quot;show=title&amp;tempid=1&amp;keyboard=&quot;+key
            });
            return source.put(&#39;surl&#39;,String(java.connect(url).raw().request().url()));
          } else {
            return source.get(&#39;surl&#39;)+&#39;&amp;page=&#39;+(page-1)
          }
        })()
        或者
        (()=&gt;{
          let base=&#39;https://www.yooread.net/e/search/&#39;;
          if(page==1){
            let url=base+&#39;index.php&#39;;
            let body=&#39;show=title&amp;tempid=1&amp;keyboard=&#39;+key;
            return base+source.put(&#39;surl&#39;,java.post(url,body,{}).header(&quot;Location&quot;));
          } else {
            return base+source.get(&#39;surl&#39;)+&#39;&amp;page=&#39;+(page-1);
          }
        })()
        </code></pre>
        <ul>
        <li>图片链接支持修改headers</li>
        </ul>
        <pre><code>let options = {
        &quot;headers&quot;: {&quot;User-Agent&quot;: &quot;xxxx&quot;,&quot;Referrer&quot;:baseUrl,&quot;Cookie&quot;:&quot;aaa=vbbb;&quot;}
        };
        &#39;&lt;img src=&quot;&#39;+src+&quot;,&quot;+JSON.stringify(options)+&#39;&quot;&gt;&#39;
        </code></pre>
        <ul>
        <li>字体解析使用<blockquote>
        <p>使用方法,在正文替换规则中使用,原理根据f1字体的字形数据到f2中查找字形对应的编码</p>
        </blockquote>
        </li>
        </ul>
        <pre><code>&lt;js&gt;
        (function(){
          var b64=String(src).match(/ttf;base64,([^\)]+)/);
          if(b64){
            var f1 = java.queryTTF(b64[1]);
            var f2 = java.queryTTF(&quot;https://alanskycn.gitee.io/teachme/assets/font/Source Han Sans CN Regular.ttf&quot;);
            // return java.replaceFont(result, f1, f2);
            return java.replaceFont(result, f1, f2, true); // 过滤掉f1中不存在的字形
          }
          return result;
        })()
        &lt;/js&gt;
        </code></pre>
        <ul>
        <li><p>购买操作</p>
        <blockquote>
        <p>可直接填写链接或者JavaScript，如果执行结果是网络链接将会自动打开浏览器,js返回true自动刷新目录和当前章节</p>
        </blockquote>
        </li>
        <li><p>图片解密</p>
        <blockquote>
        <p>适用于图片需要二次解密的情况，直接填写JavaScript，返回解密后的<code>ByteArray</code><br>部分变量说明：java（仅支持<a href="https://github.com/gedoor/legado/blob/master/app/src/main/java/io/legado/app/help/JsExtensions.kt">js扩展类</a>），result为待解密图片的<code>ByteArray</code>，src为图片链接</p>
        </blockquote>
        </li>
        </ul>
        <pre><code class="language-js">java.createSymmetricCrypto(&quot;AES/CBC/PKCS5Padding&quot;, key, iv).decrypt(result)
        </code></pre>
        <pre><code class="language-js">function decodeImage(data, key) {
          var input = new Packages.java.io.ByteArrayInputStream(data)
          var out = new Packages.java.io.ByteArrayOutputStream()
          var byte
          while ((byte = input.read()) != -1) {
            out.write(byte ^ key)
          }
          return out.toByteArray()
        }

        decodeImage(result, key)
        </code></pre>
        <ul>
        <li>封面解密<blockquote>
        <p>同图片解密 其中result为待解密封面的<code>inputStream</code></p>
        </blockquote>
        </li>
        </ul>
        <pre><code class="language-js">java.createSymmetricCrypto(&quot;AES/CBC/PKCS5Padding&quot;, key, iv).decrypt(result)
        </code></pre>
        <pre><code class="language-js">function decodeImage(data, key) {
          var out = new Packages.java.io.ByteArrayOutputStream()
          var byte
          while ((byte = data.read()) != -1) {
            out.write(byte ^ key)
          }
          return out.toByteArray()
        }

        decodeImage(result, key)
        </code></pre>
        </body></html>
        """#
}
