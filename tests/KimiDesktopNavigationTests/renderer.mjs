// Evaluate the production expression against a small renderer fixture, never a user's session.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
const expression = fs.readFileSync(process.argv[2], 'utf8');
let checks = 0;
async function scenario(options = {}) {
    const store = {activeSessionId: 'session_original', sessions: options.cold ? [] : [{id: 'session_target'}]};
    let currentURL = new URL('app://renderer/sessions/session_original');
    let navigations = 0, requests = 0;
    const location = {
        get protocol() { return currentURL.protocol; }, get host() { return currentURL.host; },
        get href() { return currentURL.href; }, get pathname() { return currentURL.pathname; },
        get search() { return currentURL.search; }
    };
    const context = {
        location,
        document: {querySelector: () => options.noStore ? null : {__vue_app__: {config: {globalProperties: {
            $pinia: {_s: new Map([['kimi.sessions', store]])}
        }}}}},
        sessionStorage: {getItem: () => options.origin ?? 'http://127.0.0.1:54322'},
        history: {pushState: (_, __, path) => { navigations++; currentURL = new URL(path, currentURL); }},
        dispatchEvent: () => { if (!options.ignoreRoute) store.activeSessionId = 'session_target'; },
        PopStateEvent: class {}, AbortController, setTimeout, clearTimeout,
        fetch: async () => {
            requests++;
            if (options.changedByUser) store.activeSessionId = 'session_user_choice';
            if (options.networkFailure) throw new Error('offline');
            return {ok: !options.missing, json: async () => ({code: 0, data: {
                id: options.mismatch ? 'session_wrong' : 'session_target', archived: options.archived ?? false
            }})};
        }
    };
    const result = await vm.runInNewContext(expression, context);
    checks++;
    return {result, navigations, requests, selected: store.activeSessionId};
}
assert.deepEqual(await scenario(), {result:true,navigations:1,requests:0,selected:'session_target'});
assert.equal((await scenario({cold:true})).result, true);
for (const options of [{missing:true}, {mismatch:true}, {archived:true}, {networkFailure:true}]) {
    const state = await scenario({cold:true,...options});
    assert.equal(state.result,false); assert.equal(state.navigations,0); assert.equal(state.selected,'session_original');
}
for (const origin of ['https://example.com','http://127.0.0.1:54323']) {
    const state = await scenario({cold:true,origin});
    assert.equal(state.requests,0); assert.equal(state.navigations,0); assert.equal(state.result,false);
}
const userChanged = await scenario({cold:true,changedByUser:true});
assert.equal(userChanged.result,false); assert.equal(userChanged.navigations,0); assert.equal(userChanged.selected,'session_user_choice');
assert.equal((await scenario({ignoreRoute:true})).result,false,'A changed URL alone cannot prove selected session');
assert.equal((await scenario({noStore:true})).result,false);
console.log(`PASS: ${checks} renderer cases: cold history, missing sessions, user navigation, endpoint limits and actual selection verification`);
