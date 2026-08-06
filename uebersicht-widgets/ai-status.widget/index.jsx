import { React } from 'uebersicht'

export const command = "/usr/bin/env python3 /Users/jabber1/Desktop/未命名文件夹/swiftbar-plugins/ai_status.py --json"
export const refreshFrequency = 10000

const COLORS = { busy: '#30d158', idle: '#ffd60a', off: '#636366' }
const LABELS = { busy: '工作中', idle: '空闲', off: '未运行' }

export const className = `
  top: 24px;
  left: 24px;
  font-family: -apple-system, "PingFang SC", "Helvetica Neue", sans-serif;
  color: rgba(255, 255, 255, 0.92);
  user-select: none;

  .card {
    background: rgba(18, 18, 22, 0.68);
    backdrop-filter: blur(24px);
    -webkit-backdrop-filter: blur(24px);
    border: 1px solid rgba(255, 255, 255, 0.08);
    border-radius: 16px;
    padding: 12px 16px 10px;
    min-width: 260px;
    box-shadow: 0 10px 32px rgba(0, 0, 0, 0.4);
  }
  .header {
    display: flex;
    justify-content: space-between;
    align-items: baseline;
    font-size: 11px;
    font-weight: 600;
    letter-spacing: 0.08em;
    color: rgba(255, 255, 255, 0.45);
    margin-bottom: 8px;
  }
  .row {
    display: flex;
    align-items: center;
    padding: 5px 0;
    border-top: 1px solid rgba(255, 255, 255, 0.05);
  }
  .row:first-of-type { border-top: none; }
  .dot {
    width: 8px;
    height: 8px;
    border-radius: 50%;
    margin-right: 10px;
    flex-shrink: 0;
  }
  .dot.busy { box-shadow: 0 0 6px ${COLORS.busy}; }
  .name { font-size: 13px; font-weight: 500; flex: 1; }
  .state { font-size: 11px; color: rgba(255, 255, 255, 0.55); margin-left: 8px; }
  .count {
    font-size: 11px;
    font-weight: 700;
    color: ${COLORS.busy};
    margin-left: 6px;
  }
  .tasks {
    margin: 0 0 4px 18px;
    padding: 0;
    list-style: none;
  }
  .tasks li {
    font-size: 11px;
    color: ${COLORS.busy};
    opacity: 0.85;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
    max-width: 300px;
    padding: 1px 0;
  }
  .latest {
    margin: 0 0 4px 18px;
    font-size: 10px;
    color: rgba(255, 255, 255, 0.35);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
    max-width: 300px;
  }
`

export const render = ({ output, error }) => {
  let data = null
  try { data = JSON.parse(output) } catch (e) {}
  if (error || !data) {
    return <div className="card"><div className="header">灵眸</div><div className="state">加载中…</div></div>
  }
  return (
    <div className="card">
      <div className="header"><span>灵眸</span><span>{data.updated_at}</span></div>
      {data.tools.map(t => (
        <div key={t.key}>
          <div className="row">
            <span className={`dot ${t.state}`} style={{ background: COLORS[t.state] }} />
            <span className="name">{t.name}</span>
            <span className="state">{LABELS[t.state]}{t.state !== 'busy' && ` · ${t.detail}`}</span>
            {t.state === 'busy' && <span className="count">{t.busy_count}</span>}
          </div>
          {t.busy_titles.length > 0 && (
            <ul className="tasks">
              {t.busy_titles.map((title, i) => <li key={i}>▶ {title}</li>)}
            </ul>
          )}
          {t.busy_titles.length === 0 && t.latest_title && (
            <div className="latest">最近：{t.latest_title} · {t.latest_age}</div>
          )}
        </div>
      ))}
    </div>
  )
}
