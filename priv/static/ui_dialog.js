/**
 * ui_dialog.js — styled, translated in-app replacements for the native
 * confirm()/alert() dialogs. Reuses the app's glass modal theme (.modal /
 * .modal-card / .modal-actions / .btn-*) so it matches the rest of the UI, and
 * routes button labels through EmquestI18n so they follow the chosen language.
 *
 *   EmquestDialog.confirm(message, { okText, cancelText, title, danger })
 *       -> Promise<boolean>   (true = confirmed, false = cancelled/Esc/backdrop)
 *   EmquestDialog.alert(message, { okText, title })
 *       -> Promise<void>
 *
 * `message` is passed already-translated by the caller (via T()); this module
 * translates only its own chrome (titles, OK/Cancel).
 */
(function () {
    const T = (s) => (window.EmquestI18n ? window.EmquestI18n.t(s) : s);

    function el(tag, cls, text) {
        const n = document.createElement(tag);
        if (cls) n.className = cls;
        if (text != null) n.textContent = text;
        return n;
    }

    function open(opts) {
        return new Promise((resolve) => {
            let done = false;
            const modal = el('div', 'modal');
            const card = el('div', 'modal-card');
            card.setAttribute('role', 'alertdialog');
            card.setAttribute('aria-modal', 'true');

            const head = el('div', 'modal-head');
            head.appendChild(el('h2', null, opts.title));
            card.appendChild(head);
            card.appendChild(el('p', 'set-desc', opts.message));

            const actions = el('div', 'modal-actions');
            const finish = (val) => { if (done) return; done = true; cleanup(); resolve(val); };
            opts.buttons.forEach((b) => {
                const btn = el('button', b.cls, b.label);
                btn.type = 'button';
                btn.addEventListener('click', () => finish(b.value));
                actions.appendChild(btn);
            });
            card.appendChild(actions);
            modal.appendChild(card);

            function onKey(e) {
                if (e.key === 'Escape') finish(opts.cancelValue);
                else if (e.key === 'Enter') finish(opts.enterValue);
            }
            function onBackdrop(e) { if (e.target === modal) finish(opts.cancelValue); }
            function cleanup() {
                document.removeEventListener('keydown', onKey);
                modal.removeEventListener('click', onBackdrop);
                modal.remove();
            }
            document.addEventListener('keydown', onKey);
            modal.addEventListener('click', onBackdrop);
            document.body.appendChild(modal);

            const btns = modal.querySelectorAll('.modal-actions button');
            if (btns.length) btns[btns.length - 1].focus();
        });
    }

    function confirm(message, o) {
        o = o || {};
        return open({
            title: o.title || T('Please confirm'),
            message,
            cancelValue: false, enterValue: true,
            buttons: [
                { label: o.cancelText || T('Cancel'), cls: 'btn-secondary', value: false },
                { label: o.okText || T('OK'), cls: o.danger ? 'btn-danger' : 'btn-primary', value: true },
            ],
        });
    }

    function alert(message, o) {
        o = o || {};
        return open({
            title: o.title || T('Notice'),
            message,
            cancelValue: undefined, enterValue: undefined,
            buttons: [{ label: o.okText || T('OK'), cls: 'btn-primary', value: undefined }],
        });
    }

    window.EmquestDialog = { confirm, alert };
})();
