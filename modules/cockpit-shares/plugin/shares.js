/*
 * DebNAS 共享管理 — Cockpit 插件（纯静态 JS，无构建步骤、无第三方依赖）
 *
 * 后端与 45Drives cockpit-file-sharing 共用，两者切换后共享不丢失：
 *   - Samba 共享：Samba 注册表（net conf listshares/showshare/addshare/setparm/delparm/delshare），
 *     要求 /etc/samba/smb.conf 的 [global] 含 "include = registry"
 *   - NFS 导出：/etc/exports.d/cockpit-file-sharing.exports（语法同 /etc/exports），不碰 /etc/exports
 *
 * 安全约定：
 *   - 所有命令用参数数组 cockpit.spawn([...])，不拼接 shell 字符串
 *   - 共享名/路径/用户名/参数键值先做白名单校验
 *   - 界面输出一律 textContent / createTextNode，不使用 innerHTML
 *   - Samba 密码只经 stdin 传给 smbpasswd -s，不出现在命令行参数里
 */
"use strict";

(function () {
    const SMB_CONF = "/etc/samba/smb.conf";
    const EXPORTS_DIR = "/etc/exports.d";
    const EXPORTS_FILE = EXPORTS_DIR + "/cockpit-file-sharing.exports";

    // ======================================================================
    // 通用工具
    // ======================================================================

    let idSeq = 0;
    function uid(prefix) {
        idSeq += 1;
        return "ds-" + prefix + "-" + idSeq;
    }

    function append(el, kids) {
        for (const c of kids.flat(Infinity)) {
            if (c === null || c === undefined || c === false) continue;
            el.appendChild(typeof c === "string" || typeof c === "number" ? document.createTextNode(String(c)) : c);
        }
        return el;
    }

    // 创建元素：attrs.text 用 textContent；on* 绑定事件；其余走 setAttribute（值转字符串，不解析 HTML）
    function h(tag, attrs, ...kids) {
        const el = document.createElement(tag);
        if (attrs) {
            for (const [k, v] of Object.entries(attrs)) {
                if (v === undefined || v === null || v === false) continue;
                if (k === "class") el.className = v;
                else if (k === "text") el.textContent = String(v);
                else if (k.startsWith("on") && typeof v === "function") el.addEventListener(k.slice(2), v);
                else if (k === "value") el.value = String(v);
                else if (k === "checked") el.checked = true;
                else if (k === "disabled") el.disabled = true;
                else el.setAttribute(k, v === true ? "" : String(v));
            }
        }
        return append(el, kids);
    }

    function clear(el) {
        while (el.firstChild) el.removeChild(el.firstChild);
    }

    // 用户可见的校验错误（直接显示 message，不当作命令失败）
    function fail(message) {
        const e = new Error(message);
        e.user = true;
        throw e;
    }

    function errText(err) {
        if (!err) return "未知错误";
        if (typeof err === "string") return err;
        const parts = [];
        if (err.message) parts.push(String(err.message));
        if (err.problem && !parts.length) parts.push(err.problem === "access-denied" ? "权限不足（需要管理员权限）" : err.problem);
        if (err.exit_status !== undefined && err.exit_status !== null && !parts.length) parts.push("退出码 " + err.exit_status);
        return parts.join("\n") || String(err);
    }

    function isNotFound(err) {
        return err && (err.problem === "not-found" || err.exit_status === 127);
    }

    function timestamp() {
        const d = new Date();
        const p = n => String(n).padStart(2, "0");
        return d.getFullYear() + p(d.getMonth() + 1) + p(d.getDate()) + "-" + p(d.getHours()) + p(d.getMinutes()) + p(d.getSeconds());
    }

    // ======================================================================
    // Cockpit 封装（统一转成原生 Promise）
    // ======================================================================

    // argv 必须是数组；默认以管理员执行，stderr 进入错误对象的 message
    function spawn(argv, opts, input) {
        if (!Array.isArray(argv)) throw new Error("spawn 需要参数数组");
        const options = Object.assign({ superuser: "require", err: "message" }, opts || {});
        const proc = cockpit.spawn(argv.map(String), options);
        if (input !== undefined) proc.input(input);
        return new Promise((resolve, reject) => proc.then(data => resolve(data), err => reject(err)));
    }

    function readFile(path, admin) {
        const f = cockpit.file(path, admin ? { superuser: "require" } : {});
        return new Promise((resolve, reject) => {
            f.read().then((content, tag) => {
                f.close();
                resolve({ content, tag });
            }, err => {
                f.close();
                reject(err);
            });
        });
    }

    // expectedTag：读取时得到的 tag（文件不存在为 "-"）；文件在此期间被改动时 Cockpit 返回 change-conflict
    function replaceFile(path, content, expectedTag) {
        const f = cockpit.file(path, { superuser: "require" });
        return new Promise((resolve, reject) => {
            f.replace(content, expectedTag).then(tag => {
                f.close();
                resolve(tag);
            }, err => {
                f.close();
                reject(err);
            });
        });
    }

    // ======================================================================
    // 校验
    // ======================================================================

    const SHARE_NAME_RE = /^[\p{L}\p{N}_][\p{L}\p{N}_.-]{0,78}\$?$/u;
    const RESERVED_SHARES = new Set(["global", "homes", "printers", "print$", "ipc$"]);
    const ACCOUNT_RE = /^[A-Za-z_][A-Za-z0-9_.-]{0,31}\$?$/;
    const PARAM_KEY_RE = /^[a-z0-9][a-z0-9 :_.-]{0,63}$/;
    // 拒绝共享的系统目录：等于或位于其下
    const FORBIDDEN_TREES = ["/etc", "/usr", "/boot", "/proc", "/sys", "/dev", "/run", "/bin", "/sbin",
        "/lib", "/lib32", "/lib64", "/libx32", "/root", "/snap", "/lost+found",
        "/var/lib", "/var/log", "/var/cache", "/var/spool", "/var/backups", "/var/run", "/var/lock", "/var/mail"];
    // 只拒绝目录本身（其子目录可以共享）
    const FORBIDDEN_EXACT = ["/", "/var", "/tmp", "/home", "/opt"];

    function shareNameError(name) {
        if (!name) return "请填写共享名";
        if (!SHARE_NAME_RE.test(name)) return "共享名只能包含字母、数字、汉字、_ . -（可用 $ 结尾表示隐藏共享），不能以 . 或 - 开头，最长 80 个字符";
        if (RESERVED_SHARES.has(name.toLowerCase())) return "「" + name + "」是 Samba 保留名称";
        return "";
    }

    function accountError(name) {
        return ACCOUNT_RE.test(name) ? "" : "用户名/组名不合法：" + name;
    }

    function normPath(p) {
        p = String(p || "").trim();
        while (p.length > 1 && p.endsWith("/")) p = p.slice(0, -1);
        return p;
    }

    function systemPathError(p) {
        if (FORBIDDEN_EXACT.includes(p)) return "不能共享系统目录 " + p + "（可共享其下的子目录）";
        for (const t of FORBIDDEN_TREES) {
            if (p === t || p.startsWith(t + "/")) return "不能共享系统目录 " + t + " 及其子目录";
        }
        return "";
    }

    function pathSyntaxError(p) {
        if (!p) return "请填写路径";
        if (!p.startsWith("/")) return "路径必须是绝对路径（以 / 开头）";
        if (/[\x00-\x1f\x7f"\\]/.test(p)) return "路径包含不允许的字符（控制字符、双引号或反斜杠）";
        if (p.includes("//")) return "路径不能包含连续的 /";
        if (p.split("/").some(s => s === "." || s === "..")) return "路径不能包含 . 或 .. 段";
        if (p.length > 1024) return "路径过长";
        return systemPathError(p);
    }

    // 在服务器上确认路径存在且为目录（解析符号链接后再查一次系统目录）
    async function checkDirRemote(p) {
        const syntax = pathSyntaxError(p);
        if (syntax) fail(syntax);
        let real;
        try {
            real = (await spawn(["realpath", "-e", "--", p])).trim();
        } catch (e) {
            fail("路径不存在：" + p);
        }
        const sys = systemPathError(real);
        if (sys) fail("路径实际指向 " + real + "，" + sys);
        const type = (await spawn(["stat", "-c", "%F", "--", real])).trim();
        if (type !== "directory") fail("路径不是目录：" + p);
        return real;
    }

    function valueError(what, v) {
        if (/[\x00-\x1f\x7f]/.test(v)) return what + "不能包含换行或控制字符";
        if (v.startsWith("-")) return what + "不能以 - 开头";
        if (v.length > 1024) return what + "过长";
        return "";
    }

    // ======================================================================
    // 界面组件（PatternFly 6 类名）
    // ======================================================================

    function button(text, variant, onClick, opts) {
        opts = opts || {};
        const cls = "pf-v6-c-button " + String(variant || "secondary").split(" ").map(v => v.startsWith("pf-") ? v : "pf-m-" + v).join(" ") +
            (opts.small ? " pf-m-small" : "") + (opts.inline ? " pf-m-inline" : "");
        const b = h("button", { type: "button", class: cls, disabled: opts.disabled, title: opts.title, "aria-label": opts.label },
            h("span", { class: "pf-v6-c-button__text", text }));
        if (onClick) b.addEventListener("click", onClick);
        return b;
    }

    function svg(cls, children) {
        const NS = "http://www.w3.org/2000/svg";
        const s = document.createElementNS(NS, "svg");
        s.setAttribute("class", cls);
        s.setAttribute("viewBox", "0 0 100 100");
        s.setAttribute("aria-hidden", "true");
        for (const [tag, attrs] of children) {
            const c = document.createElementNS(NS, tag);
            for (const [k, v] of Object.entries(attrs)) c.setAttribute(k, v);
            s.appendChild(c);
        }
        return s;
    }

    function spinner(size) {
        const s = svg("pf-v6-c-spinner pf-m-" + (size || "lg"), [["circle", { class: "pf-v6-c-spinner__path", cx: "50", cy: "50", r: "45", fill: "none" }]]);
        s.setAttribute("role", "progressbar");
        s.removeAttribute("aria-hidden");
        s.setAttribute("aria-label", "加载中");
        return s;
    }

    function loading(text) {
        return h("div", { class: "ds-loading" }, spinner("lg"), h("span", { text: text || "加载中…" }));
    }

    const ALERT_GLYPH = { info: "i", success: "✓", warning: "!", danger: "!", custom: "i" };

    function alertBox(kind, title, desc, actions, onClose) {
        const el = h("div", { class: "pf-v6-c-alert pf-m-inline pf-m-" + kind, role: kind === "danger" ? "alert" : undefined },
            h("div", { class: "pf-v6-c-alert__icon" }, h("span", { class: "ds-alert-glyph ds-alert-glyph-" + kind, "aria-hidden": "true", text: ALERT_GLYPH[kind] || "i" })),
            h("p", { class: "pf-v6-c-alert__title", text: title }),
            onClose ? h("div", { class: "pf-v6-c-alert__action" },
                h("button", { type: "button", class: "pf-v6-c-button pf-m-plain", "aria-label": "关闭提示", onclick: onClose, text: "✕" })) : null,
            desc ? h("div", { class: "pf-v6-c-alert__description" }, desc) : null,
            actions && actions.length ? h("div", { class: "pf-v6-c-alert__action-group" }, actions) : null);
        return el;
    }

    function card(title, actions, body, extraClass) {
        return h("div", { class: "pf-v6-c-card ds-card" + (extraClass ? " " + extraClass : "") },
            h("div", { class: "pf-v6-c-card__header" },
                h("div", { class: "pf-v6-c-card__header-main" },
                    h("div", { class: "pf-v6-c-card__title" }, h("h2", { class: "pf-v6-c-card__title-text", text: title }))),
                actions && actions.length ? h("div", { class: "pf-v6-c-card__actions" }, actions) : null),
            h("div", { class: "pf-v6-c-card__body" }, body));
    }

    // cells：字符串 / 节点 / { node, action: true }
    function table(caption, headers, rows) {
        return h("table", { class: "pf-v6-c-table pf-m-grid-md pf-m-compact ds-table", role: "grid", "aria-label": caption },
            h("thead", { class: "pf-v6-c-table__thead" },
                h("tr", { class: "pf-v6-c-table__tr" }, headers.map(t => h("th", { class: "pf-v6-c-table__th", scope: "col", text: t })))),
            h("tbody", { class: "pf-v6-c-table__tbody" }, rows.map(cells =>
                h("tr", { class: "pf-v6-c-table__tr" }, cells.map((c, i) => {
                    const isAction = c && typeof c === "object" && c.action;
                    return h("td", { class: "pf-v6-c-table__td" + (isAction ? " ds-actions-cell" : ""), "data-label": headers[i] || "" },
                        isAction ? c.node : c);
                })))));
    }

    function emptyState(title, body, actions) {
        return h("div", { class: "pf-v6-c-empty-state pf-m-sm" },
            h("div", { class: "pf-v6-c-empty-state__content" },
                h("div", { class: "pf-v6-c-empty-state__header" },
                    h("div", { class: "pf-v6-c-empty-state__title" }, h("h3", { class: "pf-v6-c-empty-state__title-text", text: title }))),
                body ? h("div", { class: "pf-v6-c-empty-state__body", text: body }) : null,
                actions && actions.length ? h("div", { class: "pf-v6-c-empty-state__footer" }, h("div", { class: "pf-v6-c-empty-state__actions" }, actions)) : null));
    }

    function label(text, color) {
        return h("span", { class: "pf-v6-c-label pf-m-compact" + (color ? " pf-m-" + color : "") },
            h("span", { class: "pf-v6-c-label__content" }, h("span", { class: "pf-v6-c-label__text", text })));
    }

    function chip(text, onRemove) {
        const l = label(text, "blue");
        l.appendChild(h("span", { class: "pf-v6-c-label__actions" },
            h("button", { type: "button", class: "pf-v6-c-button pf-m-plain pf-m-no-padding ds-chip-x", "aria-label": "移除 " + text, onclick: onRemove, text: "✕" })));
        return l;
    }

    function helperText(text, kind) {
        return h("div", { class: "pf-v6-c-form__helper-text" },
            h("div", { class: "pf-v6-c-helper-text" },
                h("div", { class: "pf-v6-c-helper-text__item" + (kind ? " pf-m-" + kind : "") },
                    h("span", { class: "pf-v6-c-helper-text__item-text", text }))));
    }

    function formGroup(labelText, control, helper, opts) {
        opts = opts || {};
        const id = control && control.dataset ? control.dataset.ctrlId : undefined;
        return h("div", { class: "pf-v6-c-form__group" + (opts.cls ? " " + opts.cls : "") },
            h("div", { class: "pf-v6-c-form__group-label" + (opts.noTopPadding ? " pf-m-no-padding-top" : "") },
                labelText ? h(id ? "label" : "span", { class: "pf-v6-c-form__label", for: id },
                    h("span", { class: "pf-v6-c-form__label-text", text: labelText }),
                    opts.required ? h("span", { class: "pf-v6-c-form__label-required", "aria-hidden": "true", text: " *" }) : null) : null),
            h("div", { class: "pf-v6-c-form__group-control" }, control, helper ? (typeof helper === "string" ? helperText(helper) : helper) : null));
    }

    function textInput(value, opts) {
        opts = opts || {};
        const id = uid("in");
        const input = h("input", {
            type: opts.type || "text", id, value: value || "", placeholder: opts.placeholder, disabled: opts.disabled,
            autocomplete: opts.autocomplete || "off", spellcheck: "false", "aria-label": opts.label
        });
        const wrap = h("span", { class: "pf-v6-c-form-control" + (opts.disabled ? " pf-m-disabled" : "") }, input);
        wrap.dataset.ctrlId = id;
        wrap.input = input;
        return wrap;
    }

    // options：[[value, text]] 或 [{ group, items: [[value, text]] }]
    function selectInput(options, value, opts) {
        opts = opts || {};
        const id = uid("sel");
        const kids = options.map(o => Array.isArray(o)
            ? h("option", { value: o[0], text: o[1] })
            : h("optgroup", { label: o.group }, o.items.map(i => h("option", { value: i[0], text: i[1] }))));
        const sel = h("select", { id, disabled: opts.disabled, "aria-label": opts.label }, kids);
        if (value !== undefined) sel.value = value;
        const wrap = h("span", { class: "pf-v6-c-form-control" + (opts.disabled ? " pf-m-disabled" : "") }, sel,
            h("span", { class: "pf-v6-c-form-control__utilities" }, h("span", { class: "pf-v6-c-form-control__toggle-icon ds-caret", "aria-hidden": "true" })));
        wrap.dataset.ctrlId = id;
        wrap.input = sel;
        return wrap;
    }

    function checkbox(text, checked, desc, opts) {
        opts = opts || {};
        const id = uid("chk");
        const input = h("input", { class: "pf-v6-c-check__input", type: "checkbox", id, checked, disabled: opts.disabled });
        const el = h("div", { class: "pf-v6-c-check" }, input,
            h("label", { class: "pf-v6-c-check__label", for: id, text }),
            desc ? h("span", { class: "pf-v6-c-check__description", text: desc }) : null);
        el.input = input;
        return el;
    }

    // 模态框：actions = [{ text, variant, run(modal) -> Promise|false }]；run 返回 false 时不关闭
    function openModal(spec) {
        const errBox = h("div", { class: "ds-modal-error" });
        const footer = h("footer", { class: "pf-v6-c-modal-box__footer" });
        const titleId = uid("mt");
        const buttons = [];
        const m = { busy: false };
        const onKey = e => {
            if (e.key === "Escape" && !m.busy && document.body.lastElementChild === backdrop) m.close();
        };
        const box = h("div", { class: "pf-v6-c-modal-box pf-m-" + (spec.size || "md"), role: "dialog", "aria-modal": "true", "aria-labelledby": titleId },
            h("div", { class: "pf-v6-c-modal-box__close" },
                h("button", { type: "button", class: "pf-v6-c-button pf-m-plain", "aria-label": "关闭", onclick: () => { if (!m.busy) m.close() }, text: "✕" })),
            h("header", { class: "pf-v6-c-modal-box__header" },
                h("h1", { class: "pf-v6-c-modal-box__title" + (spec.danger ? " pf-m-danger" : ""), id: titleId },
                    h("span", { class: "pf-v6-c-modal-box__title-text", text: spec.title }))),
            h("div", { class: "pf-v6-c-modal-box__body" }, errBox, spec.body),
            footer);
        const backdrop = h("div", { class: "pf-v6-c-backdrop ds-backdrop" }, h("div", { class: "pf-v6-l-bullseye" }, box));

        m.close = () => {
            backdrop.remove();
            document.removeEventListener("keydown", onKey);
            if (spec.onClose) spec.onClose();
        };
        m.setError = (title, detail) => {
            clear(errBox);
            if (title) errBox.appendChild(alertBox("danger", title, detail ? h("pre", { class: "ds-pre", text: detail }) : null));
            if (title) errBox.scrollIntoView({ block: "nearest" });
        };
        const setDisabled = d => buttons.forEach(b => { b.disabled = d });

        for (const a of spec.actions || []) {
            const b = button(a.text, a.variant || "secondary", () => {
                if (m.busy) return;
                if (!a.run) {
                    m.close();
                    return;
                }
                m.setError(null);
                m.busy = true;
                setDisabled(true);
                const sp = a.variant === "primary" || a.variant === "danger" ? spinner("md") : null;
                if (sp) {
                    sp.classList.add("ds-btn-spinner");
                    b.prepend(sp);
                }
                Promise.resolve().then(() => a.run(m)).then(r => {
                    m.busy = false;
                    if (sp) sp.remove();
                    if (r === false) setDisabled(false);
                    else m.close();
                }, err => {
                    m.busy = false;
                    if (sp) sp.remove();
                    setDisabled(false);
                    if (err && err.user) m.setError(err.message);
                    else m.setError(a.errorTitle || "操作失败", errText(err));
                });
            });
            buttons.push(b);
            footer.appendChild(b);
        }
        document.body.appendChild(backdrop);
        document.addEventListener("keydown", onKey);
        const first = box.querySelector("input:not([disabled]), select:not([disabled])");
        if (first) first.focus();
        return m;
    }

    function confirmDialog(title, message, confirmText, run, opts) {
        opts = opts || {};
        return openModal({
            title, size: "sm", danger: opts.danger !== false,
            body: typeof message === "string" ? h("p", { text: message }) : message,
            actions: [
                { text: confirmText, variant: opts.danger === false ? "primary" : "danger", run, errorTitle: opts.errorTitle },
                { text: "取消", variant: "link" }
            ]
        });
    }

    // ======================================================================
    // 页面框架：标签页、通知、管理员权限
    // ======================================================================

    const TABS = [
        ["smb", "Samba 共享"],
        ["smb-global", "Samba 设置"],
        ["nfs", "NFS 导出"],
        ["users", "共享用户"]
    ];
    const state = { admin: null, tab: "smb" };
    let root, tabBar, notices, content, adminBox;

    function notify(kind, title, detail) {
        const el = alertBox(kind, title, detail ? h("pre", { class: "ds-pre", text: detail }) : null, null, () => el.remove());
        notices.appendChild(el);
        if (kind === "success") setTimeout(() => el.remove(), 4000);
    }

    function lockedState() {
        return emptyState("需要管理员权限",
            "此页面需要管理员权限。请点击 Cockpit 顶栏右上角的「受限访问」（管理员访问）按钮并输入密码，切换为管理员模式后页面会自动刷新。");
    }

    function renderAdminBox() {
        clear(adminBox);
        if (state.admin === false) {
            adminBox.appendChild(alertBox("warning", "当前为受限访问模式",
                h("p", { text: "查看和修改共享需要管理员权限：请点击 Cockpit 顶栏右上角的「受限访问」（管理员访问）按钮，输入密码切换为管理员模式。" })));
        }
    }

    function renderTabs() {
        clear(tabBar);
        for (const [key, text] of TABS) {
            const current = key === state.tab;
            tabBar.appendChild(h("li", { class: "ds-tabs__item" + (current ? " ds-m-current" : ""), role: "presentation" },
                h("button", {
                    type: "button", class: "ds-tabs__link", role: "tab", "aria-selected": current ? "true" : "false",
                    onclick: () => goTab(key)
                }, h("span", { text }))));
        }
    }

    function goTab(key) {
        if (cockpit.location && typeof cockpit.location.go === "function") cockpit.location.go([key]);
        else showTab(key);
    }

    function showTab(key) {
        if (!TABS.some(t => t[0] === key)) key = "smb";
        state.tab = key;
        renderTabs();
        clear(content);
        if (state.admin === null) {
            content.appendChild(loading("正在检查权限…"));
            return;
        }
        const view = { smb: SmbView, "smb-global": SmbGlobalView, nfs: NfsView, users: UsersView }[key];
        view.render(content);
    }

    function applyTheme() {
        let style = "auto";
        try {
            style = window.localStorage.getItem("shell:style") || "auto";
        } catch (e) { /* 无 localStorage 时按跟随系统处理 */ }
        const dark = style === "dark" || (style === "auto" && window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches);
        document.documentElement.classList.toggle("pf-v6-theme-dark", !!dark);
    }

    // 检测 PatternFly 6 样式是否可用（用于兜底样式开关）
    function detectPatternfly() {
        const probe = h("button", { class: "pf-v6-c-button pf-m-primary ds-probe", type: "button" });
        document.body.appendChild(probe);
        const ok = getComputedStyle(probe).getPropertyValue("--pf-v6-c-button--BorderRadius").trim() !== "";
        probe.remove();
        if (!ok) document.documentElement.classList.add("ds-nopf");
    }

    // ======================================================================
    // 服务状态（systemctl show，无需管理员权限读取）
    // ======================================================================

    async function serviceStatus(units) {
        const out = await spawn(["systemctl", "show", "--no-pager", "--property=Id,LoadState,ActiveState,SubState,UnitFileState", "--"].concat(units),
            { superuser: "try" });
        const result = {};
        let cur = {};
        const blocks = [];
        for (const line of out.split("\n").concat([""])) {
            if (!line.trim()) {
                if (Object.keys(cur).length) blocks.push(cur);
                cur = {};
                continue;
            }
            const i = line.indexOf("=");
            if (i > 0) cur[line.slice(0, i)] = line.slice(i + 1);
        }
        units.forEach((u, idx) => { result[u] = blocks[idx] || { LoadState: "not-found" } });
        return result;
    }

    function serviceRow(unit, title, st, onChanged) {
        const installed = st.LoadState !== "not-found";
        const active = st.ActiveState === "active";
        const enabled = st.UnitFileState === "enabled";
        const status = !installed ? label("未安装", "orange")
            : active ? label("运行中", "green")
                : st.ActiveState === "failed" ? label("启动失败", "red") : label("已停止", "grey");
        const boot = installed ? label(enabled ? "开机启动" : (st.UnitFileState === "masked" ? "已屏蔽" : "开机不启动"), enabled ? "blue" : "grey") : null;
        const act = (argv, okText) => {
            spawn(argv).then(() => {
                notify("success", okText);
                onChanged();
            }, err => notify("danger", "操作失败：" + argv.join(" "), errText(err)));
        };
        const actions = [];
        if (installed && state.admin) {
            if (!active || !enabled) actions.push(button("启用并启动", "secondary", () => act(["systemctl", "enable", "--now", unit], title + " 已启用并启动"), { small: true }));
            if (active) actions.push(button("重启", "secondary", () => act(["systemctl", "restart", unit], title + " 已重启"), { small: true }));
            if (active) {
                actions.push(button("停止", "link pf-m-danger", () => confirmDialog("停止 " + title + "？", "停止后客户端将无法访问该服务上的共享，并取消开机启动。", "停止",
                    () => spawn(["systemctl", "disable", "--now", unit]).then(() => {
                        notify("success", title + " 已停止");
                        onChanged();
                    })), { small: true }));
            }
        }
        return h("div", { class: "ds-service-row" },
            h("div", { class: "ds-service-name" }, h("strong", { text: title }), h("span", { class: "ds-muted", text: unit })),
            h("div", { class: "ds-service-status" }, status, boot),
            h("div", { class: "ds-service-actions" }, actions));
    }

    // ======================================================================
    // Samba：smb.conf 解析与注册表
    // ======================================================================

    function normKey(k) {
        return String(k).trim().toLowerCase().replace(/\s+/g, " ");
    }

    // 返回 [{ name, start, end, params: [[key, value]] }]，start/end 为行号（end 不含）
    function parseSmbConf(text) {
        const lines = String(text || "").split("\n");
        const sections = [];
        let cur = null;
        lines.forEach((raw, i) => {
            const line = raw.trim();
            const m = /^\[([^\]]+)\]/.exec(line);
            if (m) {
                if (cur) cur.end = i;
                cur = { name: m[1].trim(), start: i, end: lines.length, params: [] };
                sections.push(cur);
                return;
            }
            if (!cur || !line || line.startsWith("#") || line.startsWith(";")) return;
            const eq = line.indexOf("=");
            if (eq > 0) cur.params.push([normKey(line.slice(0, eq)), line.slice(eq + 1).trim()]);
        });
        return { lines, sections };
    }

    function registryEnabled(text) {
        const g = parseSmbConf(text).sections.find(s => s.name.toLowerCase() === "global");
        if (!g) return false;
        return g.params.some(([k, v]) => (k === "include" || k === "config backend") && v.toLowerCase() === "registry");
    }

    // 在 [global] 最后一个参数行之后插入 include = registry；无 [global] 时在文件开头新建
    function addRegistryInclude(text) {
        const parsed = parseSmbConf(text);
        const lines = parsed.lines.slice();
        const g = parsed.sections.find(s => s.name.toLowerCase() === "global");
        if (!g) return "[global]\n   include = registry\n\n" + String(text || "");
        let insertAt = g.start + 1;
        for (let i = g.start + 1; i < g.end; i++) {
            const l = lines[i].trim();
            if (l && !l.startsWith("#") && !l.startsWith(";")) insertAt = i + 1;
        }
        lines.splice(insertAt, 0, "   include = registry");
        return lines.join("\n");
    }

    function removeSections(text, names) {
        const parsed = parseSmbConf(text);
        const drop = new Set(names.map(n => n.toLowerCase()));
        const keep = new Array(parsed.lines.length).fill(true);
        for (const s of parsed.sections) {
            if (!drop.has(s.name.toLowerCase())) continue;
            for (let i = s.start; i < s.end; i++) keep[i] = false;
        }
        return parsed.lines.filter((_, i) => keep[i]).join("\n");
    }

    const SKIP_TEXT_SECTIONS = new Set(["global", "printers", "print$", "homes"]);

    function isTrue(v) {
        return ["yes", "true", "1", "on"].includes(String(v).trim().toLowerCase());
    }

    function yn(b) {
        return b ? "yes" : "no";
    }

    function splitList(v) {
        return String(v || "").split(/[\s,]+/).map(x => x.replace(/^"|"$/g, "")).filter(Boolean);
    }

    function parseShowshare(text) {
        const params = [];
        for (const raw of String(text || "").split("\n")) {
            const line = raw.trim();
            if (!line || line.startsWith("[") || line.startsWith("#") || line.startsWith(";")) continue;
            const i = line.indexOf("=");
            if (i <= 0) continue;
            params.push([normKey(line.slice(0, i)), line.slice(i + 1).trim()]);
        }
        return params;
    }

    const MANAGED_KEYS = new Set(["path", "comment", "read only", "writeable", "writable", "write ok", "guest ok", "public",
        "browseable", "browsable", "inherit permissions", "valid users", "fruit:time machine", "fruit:time machine max size"]);
    const TM_VFS = ["catia", "fruit", "streams_xattr"];

    function shareFromParams(name, params) {
        const s = {
            name, path: "", comment: "", readOnly: true, guestOk: false, browseable: true,
            inheritPermissions: false, validUsers: [], timeMachine: false, tmMaxSize: "", extra: []
        };
        for (const [k, v] of params) {
            switch (k) {
            case "path": s.path = v; break;
            case "comment": s.comment = v; break;
            case "read only": s.readOnly = isTrue(v); break;
            case "writeable": case "writable": case "write ok": s.readOnly = !isTrue(v); break;
            case "guest ok": case "public": s.guestOk = isTrue(v); break;
            case "browseable": case "browsable": s.browseable = isTrue(v); break;
            case "inherit permissions": s.inheritPermissions = isTrue(v); break;
            case "valid users": s.validUsers = splitList(v); break;
            case "fruit:time machine": s.timeMachine = isTrue(v); break;
            case "fruit:time machine max size": s.tmMaxSize = v; break;
            default: s.extra.push([k, v]);
            }
        }
        return s;
    }

    function shareToParams(s) {
        const p = [["path", s.path]];
        if (s.comment) p.push(["comment", s.comment]);
        p.push(["read only", yn(s.readOnly)], ["guest ok", yn(s.guestOk)], ["browseable", yn(s.browseable)]);
        if (s.inheritPermissions) p.push(["inherit permissions", "yes"]);
        if (s.validUsers.length) p.push(["valid users", s.validUsers.join(" ")]);
        const extra = s.extra.map(([k, v]) => [normKey(k), v]);
        if (s.timeMachine) {
            p.push(["fruit:time machine", "yes"]);
            if (s.tmMaxSize) p.push(["fruit:time machine max size", s.tmMaxSize]);
            const vi = extra.findIndex(([k]) => k === "vfs objects");
            const cur = vi >= 0 ? splitList(extra[vi][1]) : [];
            const merged = TM_VFS.concat(cur.filter(x => !TM_VFS.includes(x))).join(" ");
            if (vi >= 0) extra[vi] = ["vfs objects", merged];
            else extra.push(["vfs objects", merged]);
        }
        return p.concat(extra);
    }

    function validateShare(s, isNew) {
        if (isNew) {
            const e = shareNameError(s.name);
            if (e) fail(e);
        }
        const pe = pathSyntaxError(s.path);
        if (pe) fail(pe);
        if (s.comment) {
            const ce = valueError("注释", s.comment);
            if (ce) fail(ce);
        }
        for (const u of s.validUsers) {
            const e = accountError(u.replace(/^[@+&]+/, ""));
            if (e) fail(e);
        }
        if (s.timeMachine && s.tmMaxSize && !/^[0-9]+[KMGTP]?$/i.test(s.tmMaxSize)) fail("Time Machine 最大容量格式应为数字加单位，如 500G、2T");
        const seen = new Set();
        for (const [k0, v] of s.extra) {
            const k = normKey(k0);
            if (!PARAM_KEY_RE.test(k)) fail("高级参数名不合法：" + k0 + "（只允许小写字母、数字、空格和 : _ . -）");
            if (MANAGED_KEYS.has(k)) fail("参数「" + k + "」请在上方对应选项中设置");
            if (seen.has(k)) fail("高级参数重复：" + k);
            seen.add(k);
            const ve = valueError("参数「" + k + "」的值", v);
            if (ve) fail(ve);
        }
    }

    async function smbListShares() {
        const out = await spawn(["net", "conf", "listshares"]);
        return out.split("\n").map(s => s.trim()).filter(s => s && s.toLowerCase() !== "global");
    }

    async function smbShowShare(name) {
        return parseShowshare(await spawn(["net", "conf", "showshare", name]));
    }

    // 以注册表当前内容为基准，逐项 setparm / delparm 到目标参数
    async function applyParams(section, desired, onlyKeys) {
        let current = [];
        try {
            current = await smbShowShare(section);
        } catch (e) {
            if (section !== "global") throw e;
        }
        const cur = new Map(current);
        const des = new Map(desired);
        for (const [k, v] of desired) {
            if (cur.get(k) !== v) await spawn(["net", "conf", "setparm", section, k, v]);
        }
        for (const [k] of current) {
            if (onlyKeys && !onlyKeys.includes(k)) continue;
            if (!des.has(k)) await spawn(["net", "conf", "delparm", section, k]);
        }
    }

    async function reloadSmbd() {
        try {
            await spawn(["smbcontrol", "smbd", "reload-config"]);
        } catch (e) { /* smbd 未运行时忽略 */ }
    }

    // 读取 smb.conf → 备份 → 写入新内容（带 tag 防并发）→ testparm 校验，失败回滚
    async function rewriteSmbConf(transform) {
        const { content, tag } = await readFile(SMB_CONF, true);
        if (content === null) fail("未找到 " + SMB_CONF + "，请先安装 Samba");
        const next = transform(content);
        if (next === content) return null;
        const backup = SMB_CONF + ".debnas-" + timestamp() + ".bak";
        await replaceFile(backup, content, "-");
        let newTag;
        try {
            newTag = await replaceFile(SMB_CONF, next, tag);
        } catch (e) {
            if (e && e.problem === "change-conflict") fail(SMB_CONF + " 已被其他程序修改，请刷新后重试");
            throw e;
        }
        try {
            await spawn(["testparm", "-s", SMB_CONF]);
        } catch (e) {
            await replaceFile(SMB_CONF, content, newTag);
            fail("修改后 testparm 校验失败，已恢复原文件：" + errText(e));
        }
        return backup;
    }

    // ======================================================================
    // 系统用户 / 组
    // ======================================================================

    async function loadAccounts() {
        const [pw, gr] = await Promise.all([readFile("/etc/passwd", false), readFile("/etc/group", false)]);
        const users = [];
        for (const line of String(pw.content || "").split("\n")) {
            const f = line.split(":");
            if (f.length < 7) continue;
            const uidN = parseInt(f[2], 10);
            users.push({ name: f[0], uid: uidN, gecos: (f[4] || "").split(",")[0], shell: f[6] });
        }
        const groups = [];
        for (const line of String(gr.content || "").split("\n")) {
            const f = line.split(":");
            if (f.length < 3) continue;
            groups.push({ name: f[0], gid: parseInt(f[2], 10) });
        }
        const normal = u => u.uid >= 1000 && u.uid < 60000;
        return {
            users: users.filter(normal),
            allUsers: users,
            groups: groups.filter(g => (g.gid >= 1000 && g.gid < 60000) || ["users", "sambashare"].includes(g.name))
        };
    }

    // ======================================================================
    // 视图：Samba 共享
    // ======================================================================

    const SmbView = {
        render(el) {
            if (!state.admin) {
                el.appendChild(lockedState());
                return;
            }
            const banner = h("div", { class: "ds-stack" });
            const body = h("div", null, loading());
            const addBtn = button("新建共享", "primary", () => this.edit(null), { disabled: true });
            el.appendChild(banner);
            el.appendChild(card("Samba 共享", [addBtn], body));
            this.load(banner, body, addBtn);
        },

        async load(banner, body, addBtn) {
            let names, conf;
            try {
                [names, conf] = await Promise.all([smbListShares(), readFile(SMB_CONF, true)]);
            } catch (err) {
                clear(body);
                if (isNotFound(err)) {
                    body.appendChild(emptyState("未安装 Samba", "请在 DebNAS 中运行「安装共享管理面板」，或执行 apt install samba。"));
                } else {
                    body.appendChild(alertBox("danger", "读取 Samba 注册表失败", h("pre", { class: "ds-pre", text: errText(err) })));
                }
                return;
            }
            let shares;
            try {
                shares = await Promise.all(names.map(async n => shareFromParams(n, await smbShowShare(n))));
            } catch (err) {
                clear(body);
                body.appendChild(alertBox("danger", "读取共享参数失败", h("pre", { class: "ds-pre", text: errText(err) })));
                return;
            }
            this.shares = shares;
            const text = conf.content || "";
            const regNames = new Set(names.map(n => n.toLowerCase()));
            const handwritten = parseSmbConf(text).sections
                .filter(s => !SKIP_TEXT_SECTIONS.has(s.name.toLowerCase()) && !regNames.has(s.name.toLowerCase()))
                .map(s => shareFromParams(s.name, s.params));

            clear(banner);
            if (conf.content !== null && !registryEnabled(text)) {
                banner.appendChild(alertBox("warning", "Samba 注册表未启用",
                    h("p", { text: "smb.conf 的 [global] 中没有 “include = registry”，此处管理的共享不会生效。启用时会先备份 smb.conf，只追加这一行，不改动其他内容。" }),
                    [button("一键启用", "primary", () => this.enableRegistry(), { small: true })]));
            }
            if (handwritten.length) {
                banner.appendChild(alertBox("info", "smb.conf 中有 " + handwritten.length + " 个手写共享不在注册表中",
                    h("p", { text: "这些共享（" + handwritten.map(s => s.name).join("、") + "）仍按 smb.conf 生效，但无法在此编辑。可选择导入到注册表统一管理。" }),
                    [button("导入到注册表…", "secondary", () => this.importDialog(handwritten), { small: true })]));
            }

            addBtn.disabled = false;
            clear(body);
            const all = shares.map(s => ({ s, hand: false })).concat(handwritten.map(s => ({ s, hand: true })));
            if (!all.length) {
                body.appendChild(emptyState("还没有 Samba 共享", "新建一个共享后，Windows / macOS / Linux 客户端即可通过 \\\\服务器\\共享名 访问。",
                    [button("新建共享", "primary", () => this.edit(null))]));
                return;
            }
            body.appendChild(table("Samba 共享列表", ["共享名", "路径", "属性", "允许的用户", "注释", ""],
                all.map(({ s, hand }) => [
                    h("span", { class: "ds-name" }, h("strong", { text: s.name }), hand ? label("smb.conf 手写", "orange") : null),
                    h("code", { class: "ds-code", text: s.path || "—" }),
                    h("span", { class: "ds-labels" },
                        s.readOnly ? label("只读", "grey") : label("读写", "green"),
                        s.guestOk ? label("访客", "orange") : null,
                        s.browseable ? null : label("隐藏", "grey"),
                        s.timeMachine ? label("Time Machine", "purple") : null),
                    s.validUsers.length ? s.validUsers.join(", ") : h("span", { class: "ds-muted", text: "所有 Samba 用户" }),
                    s.comment || "",
                    {
                        action: true,
                        node: hand ? h("span", { class: "ds-muted", text: "导入后可编辑" }) : h("span", { class: "ds-row-actions" },
                            button("编辑", "link", () => this.edit(s), { inline: true }),
                            button("删除", "link pf-m-danger", () => this.remove(s), { inline: true }))
                    }
                ])));
        },

        refresh() {
            showTab("smb");
        },

        enableRegistry() {
            confirmDialog("启用 Samba 注册表",
                h("div", null,
                    h("p", { text: "将在 " + SMB_CONF + " 的 [global] 末尾追加一行 “include = registry”。" }),
                    h("p", { text: "修改前会在同目录生成 smb.conf.debnas-<时间>.bak 备份；修改后用 testparm 校验，失败自动恢复。原有内容（包括手写共享）保持不变。" })),
                "启用", async () => {
                    const backup = await rewriteSmbConf(t => registryEnabled(t) ? t : addRegistryInclude(t));
                    await reloadSmbd();
                    notify("success", "已启用 Samba 注册表", backup ? "备份：" + backup : null);
                    this.refresh();
                }, { danger: false });
        },

        importDialog(handwritten) {
            const checks = handwritten.map(s => {
                const c = checkbox(s.name, true, s.path || "");
                c.shareName = s.name;
                return c;
            });
            const removeChk = checkbox("导入后从 smb.conf 删除这些段", false, "会先备份 smb.conf。不勾选时原文件保持不变，同名共享会同时存在于 smb.conf 和注册表（参数合并），建议导入确认无误后再删除。");
            openModal({
                title: "导入手写共享到注册表",
                size: "md",
                body: h("div", { class: "ds-stack" },
                    h("p", { text: "使用 “net conf import” 把选中的共享从 smb.conf 复制到 Samba 注册表，注册表中其他共享不受影响。" }),
                    h("div", { class: "ds-check-list" }, checks),
                    removeChk),
                actions: [{
                    text: "导入", variant: "primary", errorTitle: "导入失败",
                    run: async () => {
                        const chosen = checks.filter(c => c.input.checked).map(c => c.shareName);
                        if (!chosen.length) fail("请至少选择一个共享");
                        for (const n of chosen) {
                            const e = shareNameError(n);
                            if (e) fail("无法导入「" + n + "」：" + e);
                        }
                        for (const n of chosen) await spawn(["net", "conf", "import", SMB_CONF, n]);
                        let backup = null;
                        if (removeChk.input.checked) backup = await rewriteSmbConf(t => removeSections(t, chosen));
                        await reloadSmbd();
                        notify("success", "已导入 " + chosen.length + " 个共享", backup ? "smb.conf 备份：" + backup : null);
                        this.refresh();
                    }
                }, { text: "取消", variant: "link" }]
            });
        },

        remove(s) {
            confirmDialog("删除共享「" + s.name + "」？", "只删除 Samba 共享配置，不会删除目录 " + s.path + " 中的任何文件。", "删除", async () => {
                await spawn(["net", "conf", "delshare", s.name]);
                notify("success", "已删除共享 " + s.name);
                this.refresh();
            }, { errorTitle: "删除失败" });
        },

        async edit(existing) {
            let accounts = { users: [], groups: [] };
            try {
                accounts = await loadAccounts();
            } catch (e) { /* 读取失败时只能手工输入 */ }
            ShareForm.open(existing, accounts, () => this.refresh());
        }
    };

    // 目录浏览对话框
    function browseDialog(start, onPick) {
        let cur = normPath(start) || "/";
        const pathLine = h("code", { class: "ds-code ds-browse-path" });
        const list = h("div", { class: "ds-browse-list" });
        const m = openModal({
            title: "选择目录", size: "sm",
            body: h("div", { class: "ds-stack" }, pathLine, list),
            actions: [
                { text: "选择此目录", variant: "primary", run: () => { onPick(cur) } },
                { text: "取消", variant: "link" }
            ]
        });
        async function load(dir) {
            clear(list);
            list.appendChild(loading());
            let out;
            try {
                out = await spawn(["find", dir, "-mindepth", "1", "-maxdepth", "1", "-type", "d", "-printf", "%f\\0"]);
            } catch (e) {
                clear(list);
                m.setError("无法读取目录 " + dir, errText(e));
                return;
            }
            m.setError(null);
            cur = dir;
            pathLine.textContent = dir;
            clear(list);
            const names = out.split("\0").filter(Boolean).sort((a, b) => a.localeCompare(b));
            if (dir !== "/") {
                const parent = dir.slice(0, dir.lastIndexOf("/")) || "/";
                list.appendChild(h("button", { type: "button", class: "ds-browse-item ds-browse-up", onclick: () => load(parent), text: "⬑  上一级" }));
            }
            if (!names.length) list.appendChild(h("div", { class: "ds-muted ds-browse-empty", text: "（没有子目录）" }));
            for (const n of names) {
                const full = (dir === "/" ? "" : dir) + "/" + n;
                const blocked = systemPathError(full);
                list.appendChild(h("button", {
                    type: "button", class: "ds-browse-item" + (blocked ? " ds-m-blocked" : ""), title: blocked || full,
                    onclick: () => load(full)
                }, h("span", { class: "ds-folder", "aria-hidden": "true" }), h("span", { text: n })));
            }
        }
        load(cur).catch(() => load("/"));
    }

    // 键值对编辑器（高级参数）
    function kvEditor(pairs) {
        const rowsBox = h("div", { class: "ds-kv-rows" });
        const rows = [];
        function addRow(k, v) {
            const ki = textInput(k, { placeholder: "参数名，如 force user", label: "参数名" });
            const vi = textInput(v, { placeholder: "值", label: "参数值" });
            const row = h("div", { class: "ds-kv-row" }, ki, vi,
                h("button", { type: "button", class: "pf-v6-c-button pf-m-plain", "aria-label": "删除参数", text: "✕", onclick: () => {
                    row.remove();
                    rows.splice(rows.indexOf(entry), 1);
                } }));
            const entry = { ki, vi };
            rows.push(entry);
            rowsBox.appendChild(row);
        }
        pairs.forEach(([k, v]) => addRow(k, v));
        const el = h("div", { class: "ds-kv" }, rowsBox, button("添加参数", "link", () => addRow("", ""), { inline: true }));
        el.value = () => rows.map(r => [r.ki.input.value.trim(), r.vi.input.value.trim()]).filter(([k, v]) => k || v);
        return el;
    }

    // 允许的用户/组选择器
    function principalPicker(selected, accounts) {
        const values = selected.slice();
        const chips = h("div", { class: "ds-chips" });
        const opts = [["", "选择用户或组…"]];
        if (accounts.users.length) opts.push({ group: "用户", items: accounts.users.map(u => [u.name, u.name + (u.gecos ? "（" + u.gecos + "）" : "")]) });
        if (accounts.groups.length) opts.push({ group: "用户组", items: accounts.groups.map(g => ["@" + g.name, "@" + g.name]) });
        const sel = selectInput(opts, "", { label: "选择用户或组" });
        const manual = textInput("", { placeholder: "或手动输入，组以 @ 开头", label: "手动输入用户或组" });
        function draw() {
            clear(chips);
            if (!values.length) chips.appendChild(h("span", { class: "ds-muted", text: "未限制（所有已设置 Samba 密码的用户）" }));
            values.forEach(v => chips.appendChild(chip(v, () => {
                values.splice(values.indexOf(v), 1);
                draw();
            })));
        }
        function add(v) {
            v = v.trim();
            if (!v || values.includes(v)) return;
            values.push(v);
            draw();
        }
        sel.input.addEventListener("change", () => {
            add(sel.input.value);
            sel.input.value = "";
        });
        const addBtn = button("添加", "secondary", () => {
            add(manual.input.value);
            manual.input.value = "";
        }, { small: true });
        draw();
        const el = h("div", { class: "ds-stack ds-stack-sm" }, chips, h("div", { class: "ds-picker-row" }, sel, manual, addBtn));
        el.value = () => values.slice();
        return el;
    }

    const ShareForm = {
        open(existing, accounts, onDone) {
            const isNew = !existing;
            const s = existing ? JSON.parse(JSON.stringify(existing)) : shareFromParams("", [["read only", "no"]]);
            const name = textInput(s.name, { disabled: !isNew, placeholder: "如 data、照片", label: "共享名" });
            const path = textInput(s.path, { placeholder: "/srv/data", label: "路径" });
            const browse = button("浏览…", "secondary", () => browseDialog(path.input.value || "/", p => { path.input.value = p }));
            const comment = textInput(s.comment, { placeholder: "可选", label: "注释" });
            const ro = checkbox("只读", s.readOnly, "勾选后所有用户只能读取");
            const guest = checkbox("允许访客访问", s.guestOk, "无需账号密码即可访问（需在「Samba 设置」中将访客映射设为 Bad User）");
            const browseable = checkbox("可浏览", s.browseable, "在网络邻居 / 共享列表中显示；取消后需输入完整路径访问");
            const inherit = checkbox("继承权限", s.inheritPermissions, "新建文件和目录继承父目录的权限");
            const picker = principalPicker(s.validUsers, accounts);
            const tm = checkbox("作为 Time Machine 备份目标", s.timeMachine, "macOS 可将此共享用作 Time Machine 备份磁盘（自动启用 catia fruit streams_xattr 模块）");
            const tmSize = textInput(s.tmMaxSize, { placeholder: "不限制，如 1T", label: "Time Machine 最大容量", disabled: !s.timeMachine });
            tm.input.addEventListener("change", () => {
                tmSize.input.disabled = !tm.input.checked;
                tmSize.classList.toggle("pf-m-disabled", !tm.input.checked);
            });
            const kv = kvEditor(s.extra);

            const form = h("form", { class: "pf-v6-c-form pf-m-horizontal ds-form", onsubmit: e => e.preventDefault() },
                formGroup("共享名", name, isNew ? "字母、数字、汉字、_ . -；以 $ 结尾为隐藏共享" : "共享名创建后不可修改", { required: true }),
                formGroup("路径", h("div", { class: "pf-v6-c-input-group ds-input-group" },
                    h("div", { class: "pf-v6-c-input-group__item pf-m-fill" }, path),
                    h("div", { class: "pf-v6-c-input-group__item" }, browse)), "必须是已存在的目录；不允许共享 /、/etc、/usr、/boot 等系统目录", { required: true }),
                formGroup("注释", comment),
                formGroup("访问", h("div", { class: "ds-stack ds-stack-sm" }, ro, guest, browseable, inherit), null, { noTopPadding: true }),
                formGroup("允许的用户/组", picker, "对应 valid users；用户与用户组的创建请到 Cockpit「账户」页"),
                formGroup("Time Machine", h("div", { class: "ds-stack ds-stack-sm" }, tm, tmSize), null, { noTopPadding: true }),
                formGroup("高级参数", kv, "直接写入 Samba 注册表，如 force user、create mask、veto files"));

            openModal({
                title: isNew ? "新建 Samba 共享" : "编辑共享「" + s.name + "」",
                size: "lg",
                body: form,
                actions: [{
                    text: isNew ? "创建" : "保存", variant: "primary", errorTitle: "保存失败",
                    run: async () => {
                        const next = Object.assign({}, s, {
                            name: isNew ? name.input.value.trim() : s.name,
                            path: normPath(path.input.value),
                            comment: comment.input.value.trim(),
                            readOnly: ro.input.checked,
                            guestOk: guest.input.checked,
                            browseable: browseable.input.checked,
                            inheritPermissions: inherit.input.checked,
                            validUsers: picker.value(),
                            timeMachine: tm.input.checked,
                            tmMaxSize: tm.input.checked ? tmSize.input.value.trim() : "",
                            extra: kv.value()
                        });
                        validateShare(next, isNew);
                        await checkDirRemote(next.path);
                        if (isNew) {
                            const existingNames = (await smbListShares()).map(n => n.toLowerCase());
                            if (existingNames.includes(next.name.toLowerCase())) fail("共享「" + next.name + "」已存在");
                            await spawn(["net", "conf", "addshare", next.name, next.path]);
                        }
                        await applyParams(next.name, shareToParams(next));
                        notify("success", (isNew ? "已创建共享 " : "已保存共享 ") + next.name);
                        onDone();
                    }
                }, { text: "取消", variant: "link" }]
            });
        }
    };

    // ======================================================================
    // 视图：Samba 设置（服务状态 + 全局参数）
    // ======================================================================

    const GLOBAL_PARAMS = [
        { key: "workgroup", label: "工作组", type: "text", placeholder: "WORKGROUP", help: "Windows 工作组名，最长 15 个字符" },
        { key: "server string", label: "服务器描述", type: "text", placeholder: "%h server (Samba)", help: "在网络邻居中显示的说明" },
        {
            key: "map to guest", label: "访客映射", type: "select", help: "共享启用「允许访客访问」时需设为 Bad User",
            options: [["", "（默认）"], ["never", "Never — 不映射"], ["bad user", "Bad User — 不存在的用户映射为访客"]]
        },
        {
            key: "server min protocol", label: "最低协议版本", type: "select", help: "提高最低版本可禁用老旧且不安全的协议",
            options: [["", "（默认，SMB2_02）"], ["SMB2_10", "SMB2_10"], ["SMB3", "SMB3"], ["SMB3_11", "SMB3_11"]]
        }
    ];

    const SmbGlobalView = {
        render(el) {
            const statusBody = h("div", null, loading());
            el.appendChild(card("服务状态", [button("刷新", "secondary", () => showTab("smb-global"), { small: true })], statusBody));
            this.loadStatus(statusBody);
            if (!state.admin) {
                el.appendChild(card("全局设置", null, lockedState()));
                return;
            }
            const cfgBody = h("div", null, loading());
            el.appendChild(card("全局设置", null, cfgBody));
            this.loadConfig(cfgBody);
        },

        async loadStatus(body) {
            try {
                const st = await serviceStatus(["smbd.service", "nmbd.service"]);
                clear(body);
                body.appendChild(serviceRow("smbd.service", "Samba 文件服务（smbd）", st["smbd.service"], () => showTab("smb-global")));
                body.appendChild(serviceRow("nmbd.service", "NetBIOS 名称服务（nmbd）", st["nmbd.service"], () => showTab("smb-global")));
            } catch (err) {
                clear(body);
                body.appendChild(alertBox("danger", "读取服务状态失败", h("pre", { class: "ds-pre", text: errText(err) })));
            }
        },

        async loadConfig(body) {
            let conf, effective;
            try {
                conf = await readFile(SMB_CONF, true);
                effective = {};
                for (const p of GLOBAL_PARAMS) {
                    effective[p.key] = (await spawn(["testparm", "-s", "--parameter-name=" + p.key])).trim();
                }
            } catch (err) {
                clear(body);
                if (isNotFound(err) || (conf && conf.content === null)) body.appendChild(emptyState("未安装 Samba", "请在 DebNAS 中运行「安装共享管理面板」，或执行 apt install samba。"));
                else body.appendChild(alertBox("danger", "读取 Samba 配置失败", h("pre", { class: "ds-pre", text: errText(err) })));
                return;
            }
            clear(body);
            const reg = registryEnabled(conf.content || "");
            body.appendChild(h("div", { class: "ds-kv-line" },
                h("span", { class: "ds-muted", text: "配置文件：" }), h("code", { class: "ds-code", text: SMB_CONF }),
                reg ? label("已启用注册表（include = registry）", "green") : label("未启用注册表", "orange")));
            if (!reg) {
                body.appendChild(alertBox("warning", "全局设置保存在 Samba 注册表中，需要先启用注册表",
                    null, [button("一键启用", "primary", () => SmbView.enableRegistry(), { small: true })]));
            }
            const controls = {};
            const form = h("form", { class: "pf-v6-c-form pf-m-horizontal ds-form ds-form-narrow", onsubmit: e => e.preventDefault() });
            for (const p of GLOBAL_PARAMS) {
                const val = effective[p.key] || "";
                let ctrl;
                if (p.type === "select") {
                    const options = p.options.slice();
                    const lower = val.toLowerCase();
                    const match = options.find(o => o[0].toLowerCase() === lower);
                    ctrl = selectInput(options, match ? match[0] : "", { label: p.label, disabled: !reg });
                } else {
                    ctrl = textInput(val, { placeholder: p.placeholder, label: p.label, disabled: !reg });
                }
                controls[p.key] = ctrl;
                form.appendChild(formGroup(p.label, ctrl, p.help));
            }
            const save = button("保存", "primary", () => this.save(controls, save), { disabled: !reg });
            form.appendChild(h("div", { class: "pf-v6-c-form__group pf-m-action" },
                h("div", { class: "pf-v6-c-form__group-label" }),
                h("div", { class: "pf-v6-c-form__group-control" }, h("div", { class: "pf-v6-c-form__actions" }, save))));
            body.appendChild(form);
        },

        async save(controls, btn) {
            const desired = [];
            for (const p of GLOBAL_PARAMS) {
                const v = controls[p.key].input.value.trim();
                if (!v) continue;
                if (p.key === "workgroup" && !/^[A-Za-z0-9_.-]{1,15}$/.test(v)) {
                    notify("danger", "工作组名不合法", "只允许字母、数字和 _ . -，最长 15 个字符");
                    return;
                }
                const ve = valueError(p.label, v);
                if (ve) {
                    notify("danger", ve);
                    return;
                }
                desired.push([p.key, v]);
            }
            btn.disabled = true;
            try {
                await applyParams("global", desired, GLOBAL_PARAMS.map(p => p.key));
                const overridden = [];
                for (const [k, v] of desired) {
                    const eff = (await spawn(["testparm", "-s", "--parameter-name=" + k])).trim();
                    if (eff.toLowerCase() !== v.toLowerCase()) overridden.push(k + "（当前生效值：" + eff + "）");
                }
                await reloadSmbd();
                if (overridden.length) notify("warning", "已保存，但以下参数被 smb.conf 中 include = registry 之后的同名设置覆盖", overridden.join("\n"));
                else notify("success", "全局设置已保存");
                showTab("smb-global");
            } catch (err) {
                btn.disabled = false;
                notify("danger", "保存全局设置失败", errText(err));
            }
        }
    };

    // ======================================================================
    // NFS：exports 解析与序列化
    // ======================================================================

    function decodeOctal(s) {
        return s.replace(/\\([0-7]{3})/g, (_, o) => String.fromCharCode(parseInt(o, 8)));
    }

    function tokenizeExport(line) {
        const toks = [];
        let i = 0;
        while (i < line.length) {
            while (i < line.length && /\s/.test(line[i])) i++;
            if (i >= line.length) break;
            if (line[i] === '"') {
                const j = line.indexOf('"', i + 1);
                if (j < 0) return null;
                toks.push(line.slice(i + 1, j));
                i = j + 1;
                continue;
            }
            let tok = "";
            while (i < line.length && !/\s/.test(line[i])) tok += line[i++];
            toks.push(decodeOctal(tok));
        }
        return toks;
    }

    // 返回 { entries: [{ comments, path, clients: [{ host, options }] } | { comments, raw }], trailing }
    function parseExports(text) {
        const entries = [];
        let pending = [];
        let buf = "";
        for (const raw of String(text || "").split("\n")) {
            if (buf) {
                buf += " " + raw.trim();
            } else {
                const t = raw.trim();
                if (!t) continue;
                if (t.startsWith("#")) {
                    pending.push(raw.replace(/\s+$/, ""));
                    continue;
                }
                buf = t;
            }
            if (buf.endsWith("\\")) {
                buf = buf.slice(0, -1).trim();
                continue;
            }
            const line = buf;
            buf = "";
            const toks = tokenizeExport(line);
            const entry = { comments: pending };
            pending = [];
            if (!toks || !toks.length || !toks[0].startsWith("/")) {
                entry.raw = line;
            } else {
                entry.path = toks[0];
                entry.clients = [];
                for (const t of toks.slice(1)) {
                    const m = /^([^()]*)(?:\(([^()]*)\))?$/.exec(t);
                    if (!m) {
                        entry.raw = line;
                        break;
                    }
                    entry.clients.push({ host: m[1], options: m[2] ? m[2].split(",").map(o => o.trim()).filter(Boolean) : [] });
                }
                if (entry.raw) {
                    delete entry.path;
                    delete entry.clients;
                }
            }
            entries.push(entry);
        }
        if (buf) entries.push({ comments: pending, raw: buf });
        else if (pending.length) return { entries, trailing: pending };
        return { entries, trailing: [] };
    }

    function quoteExportPath(p) {
        return /^[A-Za-z0-9_/.+@:,-]+$/.test(p) ? p : '"' + p + '"';
    }

    function serializeExports(model) {
        const out = [];
        for (const e of model.entries) {
            out.push(...e.comments);
            if (e.raw !== undefined) out.push(e.raw);
            else out.push([quoteExportPath(e.path)].concat(e.clients.map(c => c.host + (c.options.length ? "(" + c.options.join(",") + ")" : ""))).join(" "));
        }
        out.push(...model.trailing);
        return out.length ? out.join("\n") + "\n" : "";
    }

    const NFS_HOST_RE = /^(\*|@[A-Za-z0-9_.-]+|[A-Za-z0-9*?._:-]+(\/[0-9.]{1,15})?)$/;
    const NFS_OPT_RE = /^[a-z_]+(=[A-Za-z0-9_.:/@+-]+)?$/;
    const NFS_KNOWN = new Set(["rw", "ro", "sync", "async", "root_squash", "no_root_squash", "all_squash", "no_subtree_check", "subtree_check", "insecure", "secure"]);

    function clientToForm(c) {
        const o = new Set(c.options);
        return {
            host: c.host,
            access: o.has("rw") ? "rw" : "ro",
            sync: o.has("async") ? "async" : "sync",
            squash: o.has("no_root_squash") ? "no_root_squash" : o.has("all_squash") ? "all_squash" : "root_squash",
            noSubtree: !o.has("subtree_check"),
            insecure: o.has("insecure"),
            custom: c.options.filter(x => !NFS_KNOWN.has(x)).join(",")
        };
    }

    function formToClient(f) {
        const opts = [f.access, f.sync, f.squash, f.noSubtree ? "no_subtree_check" : "subtree_check"];
        if (f.insecure) opts.push("insecure");
        for (const c of f.custom.split(",").map(x => x.trim()).filter(Boolean)) {
            if (!NFS_OPT_RE.test(c)) fail("自定义选项不合法：" + c);
            if (NFS_KNOWN.has(c)) fail("选项 " + c + " 请用上方的选项设置");
            if (!opts.includes(c)) opts.push(c);
        }
        if (!f.host || !NFS_HOST_RE.test(f.host)) fail("客户端格式不合法：" + (f.host || "（空）") + "。示例：192.168.1.0/24、client.lan、*");
        return { host: f.host, options: opts };
    }

    // ======================================================================
    // 视图：NFS 导出
    // ======================================================================

    const NfsView = {
        render(el) {
            const statusBody = h("div", null, loading());
            el.appendChild(card("NFS 服务状态", [button("刷新", "secondary", () => showTab("nfs"), { small: true })], statusBody));
            if (!state.admin) {
                this.loadStatus(statusBody);
                el.appendChild(card("NFS 导出", null, lockedState()));
                return;
            }
            const addBtn = button("新建导出", "primary", () => this.edit(null), { disabled: true });
            const body = h("div", null, loading());
            el.appendChild(card("NFS 导出", [addBtn], body));
            this.loadStatus(statusBody).then(installed => this.load(body, addBtn, installed));
        },

        async loadStatus(body) {
            try {
                const st = (await serviceStatus(["nfs-server.service"]))["nfs-server.service"];
                clear(body);
                body.appendChild(serviceRow("nfs-server.service", "NFS 服务端（nfs-server）", st, () => showTab("nfs")));
                return st.LoadState !== "not-found";
            } catch (err) {
                clear(body);
                body.appendChild(alertBox("danger", "读取服务状态失败", h("pre", { class: "ds-pre", text: errText(err) })));
                return false;
            }
        },

        async load(body, addBtn, installed) {
            let file;
            try {
                file = await readFile(EXPORTS_FILE, true);
            } catch (err) {
                clear(body);
                body.appendChild(alertBox("danger", "读取 " + EXPORTS_FILE + " 失败", h("pre", { class: "ds-pre", text: errText(err) })));
                return;
            }
            this.loaded = { content: file.content === null ? null : file.content, tag: file.tag };
            this.model = parseExports(file.content || "");
            clear(body);
            body.appendChild(h("p", { class: "ds-muted ds-file-hint" }, "配置文件：", h("code", { class: "ds-code", text: EXPORTS_FILE }),
                "（与 45Drives 文件共享插件共用；/etc/exports 不受影响）"));
            if (!installed) {
                body.appendChild(emptyState("未安装 NFS 服务端",
                    "在 DebNAS 中运行「安装共享管理面板」并选择安装 NFS（或在 debnas.conf 设置 file_sharing_nfs=1），也可执行 apt install nfs-kernel-server。"));
                return;
            }
            addBtn.disabled = false;
            const entries = this.model.entries;
            if (!entries.length) {
                body.appendChild(emptyState("还没有 NFS 导出", "导出一个目录后，Linux / macOS 客户端即可通过 mount -t nfs 服务器:/路径 挂载。",
                    [button("新建导出", "primary", () => this.edit(null))]));
                return;
            }
            body.appendChild(table("NFS 导出列表", ["路径", "客户端与选项", ""], entries.map((e, idx) => {
                if (e.raw !== undefined) {
                    return [h("code", { class: "ds-code", text: e.raw }), h("span", { class: "ds-muted", text: "无法解析，保持原样" }),
                        { action: true, node: h("span", { class: "ds-row-actions" }, button("删除", "link pf-m-danger", () => this.remove(idx), { inline: true })) }];
                }
                return [
                    h("code", { class: "ds-code", text: e.path }),
                    h("div", { class: "ds-clients" }, e.clients.length ? e.clients.map(c => h("div", { class: "ds-client" },
                        h("strong", { text: c.host || "（所有主机）" }), h("span", { class: "ds-muted", text: c.options.join(", ") }))) : h("span", { class: "ds-muted", text: "（未指定客户端）" })),
                    {
                        action: true,
                        node: h("span", { class: "ds-row-actions" },
                            button("编辑", "link", () => this.edit(idx), { inline: true }),
                            button("删除", "link pf-m-danger", () => this.remove(idx), { inline: true }))
                    }
                ];
            })));
        },

        // 写入前重新读取并与加载时内容比较；写入带 tag，exportfs 失败时回滚
        async save(model) {
            const cur = await readFile(EXPORTS_FILE, true);
            const before = this.loaded.content;
            if ((cur.content === null ? null : cur.content) !== before) fail("文件已被其他程序修改，请刷新页面后重试（" + EXPORTS_FILE + "）");
            const text = serializeExports(model);
            if (cur.tag === "-") await spawn(["mkdir", "-p", "--", EXPORTS_DIR]);
            let newTag;
            try {
                newTag = await replaceFile(EXPORTS_FILE, text, cur.tag);
            } catch (e) {
                if (e && e.problem === "change-conflict") fail("文件已被其他程序修改，请刷新页面后重试（" + EXPORTS_FILE + "）");
                throw e;
            }
            try {
                await spawn(["exportfs", "-ra"]);
            } catch (e) {
                await replaceFile(EXPORTS_FILE, before, newTag);
                try {
                    await spawn(["exportfs", "-ra"]);
                } catch (e2) { /* 回滚后再次应用失败时以首个错误为准 */ }
                fail("exportfs -ra 失败，已恢复原文件：\n" + errText(e));
            }
        },

        remove(idx) {
            const e = this.model.entries[idx];
            confirmDialog("删除 NFS 导出？", "将删除导出 " + (e.path || e.raw) + "，不会删除目录中的任何文件。", "删除", async () => {
                const next = { entries: this.model.entries.filter((_, i) => i !== idx), trailing: this.model.trailing };
                await this.save(next);
                notify("success", "已删除导出 " + (e.path || ""));
                showTab("nfs");
            }, { errorTitle: "删除失败" });
        },

        edit(idx) {
            const isNew = idx === null;
            const entry = isNew ? { comments: [], path: "", clients: [{ host: "", options: ["rw", "sync", "root_squash", "no_subtree_check"] }] }
                : JSON.parse(JSON.stringify(this.model.entries[idx]));
            const path = textInput(entry.path, { placeholder: "/srv/nfs/data", label: "路径" });
            const browse = button("浏览…", "secondary", () => browseDialog(path.input.value || "/", p => { path.input.value = p }));
            const clientsBox = h("div", { class: "ds-stack ds-stack-sm" });
            const clientRows = [];

            const addClient = c => {
                const f = clientToForm(c);
                const host = textInput(f.host, { placeholder: "192.168.1.0/24、host.lan 或 *", label: "客户端" });
                const access = selectInput([["rw", "读写（rw）"], ["ro", "只读（ro）"]], f.access, { label: "访问" });
                const sync = selectInput([["sync", "同步写入（sync）"], ["async", "异步写入（async）"]], f.sync, { label: "写入" });
                const squash = selectInput([["root_squash", "root 映射为匿名（root_squash，推荐）"], ["no_root_squash", "保留 root 权限（no_root_squash）"],
                    ["all_squash", "全部映射为匿名（all_squash）"]], f.squash, { label: "用户映射" });
                const noSub = checkbox("no_subtree_check", f.noSubtree, null);
                const insecure = checkbox("insecure（允许非特权端口，macOS 需要）", f.insecure, null);
                const custom = textInput(f.custom, { placeholder: "其他选项，逗号分隔，如 fsid=0,anonuid=1000", label: "其他选项" });
                const box = h("div", { class: "ds-client-edit" },
                    h("div", { class: "ds-client-grid" },
                        formGroup("客户端", host), formGroup("访问", access), formGroup("写入", sync), formGroup("用户映射", squash)),
                    h("div", { class: "ds-client-flags" }, noSub, insecure),
                    formGroup("其他选项", custom),
                    h("div", { class: "ds-client-remove" }, button("移除此客户端", "link pf-m-danger", () => {
                        box.remove();
                        clientRows.splice(clientRows.indexOf(row), 1);
                    }, { inline: true, small: true })));
                const row = {
                    value: () => ({
                        host: host.input.value.trim(), access: access.input.value, sync: sync.input.value, squash: squash.input.value,
                        noSubtree: noSub.input.checked, insecure: insecure.input.checked, custom: custom.input.value.trim()
                    })
                };
                clientRows.push(row);
                clientsBox.appendChild(box);
            };
            entry.clients.forEach(addClient);

            const form = h("form", { class: "pf-v6-c-form ds-form", onsubmit: e => e.preventDefault() },
                formGroup("路径", h("div", { class: "pf-v6-c-input-group ds-input-group" },
                    h("div", { class: "pf-v6-c-input-group__item pf-m-fill" }, path),
                    h("div", { class: "pf-v6-c-input-group__item" }, browse)), "必须是已存在的目录；不允许导出系统目录", { required: true }),
                formGroup("客户端", h("div", { class: "ds-stack ds-stack-sm" }, clientsBox,
                    button("添加客户端", "link", () => addClient({ host: "", options: ["rw", "sync", "root_squash", "no_subtree_check"] }), { inline: true }))));

            openModal({
                title: isNew ? "新建 NFS 导出" : "编辑 NFS 导出",
                size: "lg",
                body: form,
                actions: [{
                    text: isNew ? "创建" : "保存", variant: "primary", errorTitle: "保存失败",
                    run: async () => {
                        const p = normPath(path.input.value);
                        const pe = pathSyntaxError(p);
                        if (pe) fail(pe);
                        if (!clientRows.length) fail("请至少添加一个客户端");
                        const clients = clientRows.map(r => formToClient(r.value()));
                        const dupHost = clients.map(c => c.host).find((hst, i, a) => a.indexOf(hst) !== i);
                        if (dupHost !== undefined) fail("客户端重复：" + dupHost);
                        if (this.model.entries.some((e, i) => i !== idx && e.path === p)) fail("该路径已有导出，请直接编辑原条目");
                        await checkDirRemote(p);
                        const updated = { comments: entry.comments || [], path: p, clients };
                        const entries = this.model.entries.slice();
                        if (isNew) entries.push(updated);
                        else entries[idx] = updated;
                        await this.save({ entries, trailing: this.model.trailing });
                        notify("success", (isNew ? "已创建导出 " : "已保存导出 ") + p);
                        showTab("nfs");
                    }
                }, { text: "取消", variant: "link" }]
            });
        }
    };

    // ======================================================================
    // 视图：共享用户（Samba 密码）
    // ======================================================================

    const UsersView = {
        render(el) {
            if (!state.admin) {
                el.appendChild(lockedState());
                return;
            }
            const accountsLink = button("打开「账户」页", "link", () => cockpit.jump("/users"), { inline: true });
            el.appendChild(alertBox("info", "Samba 使用独立的访问密码",
                h("p", null, "这里为系统用户设置或删除 Samba 访问密码（smbpasswd）。创建/删除用户和用户组请到 Cockpit 自带的「账户」页面：", accountsLink)));
            const body = h("div", null, loading());
            el.appendChild(card("共享用户", [button("刷新", "secondary", () => showTab("users"), { small: true })], body));
            this.load(body);
        },

        async load(body) {
            let accounts, pdb;
            try {
                accounts = await loadAccounts();
                pdb = await spawn(["pdbedit", "-L"]);
            } catch (err) {
                clear(body);
                if (isNotFound(err)) body.appendChild(emptyState("未安装 Samba", "请在 DebNAS 中运行「安装共享管理面板」，或执行 apt install samba。"));
                else body.appendChild(alertBox("danger", "读取 Samba 用户失败", h("pre", { class: "ds-pre", text: errText(err) })));
                return;
            }
            const smbUsers = new Map();
            for (const line of pdb.split("\n")) {
                const f = line.split(":");
                if (f.length >= 2 && f[0]) smbUsers.set(f[0], { uid: f[1], full: f[2] || "" });
            }
            const rows = accounts.users.map(u => ({ name: u.name, uid: u.uid, gecos: u.gecos, system: true, smb: smbUsers.has(u.name) }));
            for (const [name, info] of smbUsers) {
                if (!rows.some(r => r.name === name)) {
                    const sys = accounts.allUsers.find(u => u.name === name);
                    rows.push({ name, uid: sys ? sys.uid : info.uid, gecos: info.full, system: !!sys, smb: true });
                }
            }
            clear(body);
            if (!rows.length) {
                body.appendChild(emptyState("没有普通用户", "请先在 Cockpit「账户」页面创建用户，再回到这里设置 Samba 密码。",
                    [button("打开「账户」页", "primary", () => cockpit.jump("/users"))]));
                return;
            }
            body.appendChild(table("共享用户列表", ["用户名", "UID", "全名", "Samba 密码", ""], rows.map(r => [
                h("strong", { text: r.name }),
                String(r.uid),
                r.gecos || "",
                h("span", { class: "ds-labels" }, r.smb ? label("已设置", "green") : label("未设置", "grey"), r.system ? null : label("系统中不存在", "orange")),
                {
                    action: true,
                    node: h("span", { class: "ds-row-actions" },
                        r.system ? button(r.smb ? "修改密码" : "设置密码", "link", () => this.setPassword(r.name, r.smb), { inline: true }) : null,
                        r.smb ? button("删除 Samba 密码", "link pf-m-danger", () => this.removeUser(r.name), { inline: true }) : null)
                }
            ])));
        },

        setPassword(name, exists) {
            if (accountError(name)) {
                notify("danger", accountError(name));
                return;
            }
            const pw1 = textInput("", { type: "password", autocomplete: "new-password", label: "新密码" });
            const pw2 = textInput("", { type: "password", autocomplete: "new-password", label: "确认密码" });
            openModal({
                title: (exists ? "修改" : "设置") + "「" + name + "」的 Samba 密码",
                size: "sm",
                body: h("form", { class: "pf-v6-c-form ds-form", onsubmit: e => e.preventDefault() },
                    formGroup("新密码", pw1, null, { required: true }),
                    formGroup("确认密码", pw2, "Samba 密码独立于系统登录密码", { required: true })),
                actions: [{
                    text: "保存", variant: "primary", errorTitle: "设置密码失败",
                    run: async () => {
                        const a = pw1.input.value;
                        if (!a) fail("请输入密码");
                        if (/[\r\n]/.test(a)) fail("密码不能包含换行");
                        if (a !== pw2.input.value) fail("两次输入的密码不一致");
                        // -s：从 stdin 读取两遍密码；密码不出现在命令行参数中
                        await spawn(["smbpasswd", "-s", "-a", name], {}, a + "\n" + a + "\n");
                        notify("success", "已" + (exists ? "修改" : "设置") + " " + name + " 的 Samba 密码");
                        showTab("users");
                    }
                }, { text: "取消", variant: "link" }]
            });
        },

        removeUser(name) {
            if (accountError(name)) {
                notify("danger", accountError(name));
                return;
            }
            confirmDialog("删除「" + name + "」的 Samba 密码？", "该用户将无法再访问 Samba 共享；系统账户本身不受影响。", "删除", async () => {
                await spawn(["smbpasswd", "-x", name]);
                notify("success", "已删除 " + name + " 的 Samba 密码");
                showTab("users");
            }, { errorTitle: "删除失败" });
        }
    };

    // ======================================================================
    // 启动
    // ======================================================================

    function init() {
        root = document.getElementById("ds-root");
        clear(root);
        applyTheme();
        window.addEventListener("storage", e => {
            if (e.key === "shell:style") applyTheme();
        });
        window.addEventListener("cockpit-style", applyTheme);
        detectPatternfly();

        adminBox = h("div", { class: "ds-admin" });
        tabBar = h("ul", { class: "ds-tabs__list", role: "tablist" });
        notices = h("div", { class: "ds-notices", "aria-live": "polite" });
        content = h("div", { class: "ds-content" });
        root.appendChild(h("header", { class: "ds-header" },
            h("h1", { class: "ds-title", text: "共享管理" }),
            h("p", { class: "ds-subtitle", text: "管理 Samba（SMB）共享、NFS 导出与共享用户。配置与 45Drives 文件共享插件互通。" })));
        root.appendChild(h("nav", { class: "ds-tabs", "aria-label": "共享管理分区" }, tabBar));
        root.appendChild(h("main", { class: "ds-main" }, adminBox, notices, content));

        const initial = cockpit.location && cockpit.location.path && cockpit.location.path[0];
        state.tab = initial || "smb";
        showTab(state.tab);
        cockpit.addEventListener("locationchanged", () => showTab((cockpit.location.path && cockpit.location.path[0]) || "smb"));

        const perm = cockpit.permission({ admin: true });
        const update = () => {
            if (perm.allowed === null || perm.allowed === undefined) return;
            const was = state.admin;
            state.admin = !!perm.allowed;
            if (was !== state.admin) {
                renderAdminBox();
                showTab(state.tab);
            }
        };
        perm.addEventListener("changed", update);
        update();
    }

    if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
    else init();
}());
