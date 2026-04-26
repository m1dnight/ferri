//! Minimal ratatui front-end.
//!
//! - top: ASCII logo
//! - bottom: scrolling log buffer fed by an [`mpsc::UnboundedSender<String>`]
//!
//! Owns the terminal: enters raw mode + alternate screen on start, restores
//! on drop (so panics don't leave the user with a corrupted shell).

use std::collections::VecDeque;
use std::io;

use ansi_to_tui::IntoText;
use crossterm::event::{Event, EventStream, KeyCode, KeyModifiers};
use crossterm::execute;
use crossterm::terminal::{
    EnterAlternateScreen, LeaveAlternateScreen, disable_raw_mode, enable_raw_mode,
};
use futures::StreamExt;
use ratatui::backend::CrosstermBackend;
use ratatui::layout::{Alignment, Constraint, Direction, Layout};
use ratatui::style::{Color, Style};
use ratatui::text::{Line, Text};
use ratatui::widgets::Paragraph;
use ratatui::{Frame, Terminal};
use tokio::sync::mpsc::UnboundedReceiver;
use tokio::time::{Duration, interval};

/// The channel half passed into the rest of the program for emitting log lines.
pub type LogSink = tokio::sync::mpsc::UnboundedSender<String>;

/// Pre-rendered colored logo as ANSI escape sequences.
/// Generate with: `script -q /dev/null artem -s 30 priv/static/images/logo-no-text-black-background.png`
/// then trim to first ESC byte. See README for the regen recipe.
const LOGO_ANSI: &[u8] = include_bytes!("../assets/logo.ansi");
const LOGO_WIDTH: u16 = 32;
const LOGO_HEIGHT: u16 = 16;

const MAX_LOG_LINES: usize = 1000;

pub async fn run(mut rx: UnboundedReceiver<String>) -> anyhow::Result<()> {
    // Parse the ANSI-colored logo once; reuse the styled Text on every redraw.
    let logo: Text<'static> = LOGO_ANSI.into_text()?;

    let _guard = TerminalGuard::new()?;

    let backend = CrosstermBackend::new(io::stdout());
    let mut term = Terminal::new(backend)?;

    let mut logs: VecDeque<String> = VecDeque::with_capacity(MAX_LOG_LINES);
    let mut tick = interval(Duration::from_millis(60));
    let mut events = EventStream::new();

    loop {
        tokio::select! {
            _ = tick.tick() => {
                term.draw(|f| draw(f, &logo, &logs))?;
            }
            line = rx.recv() => match line {
                Some(line) => {
                    logs.push_back(line);
                    if logs.len() > MAX_LOG_LINES {
                        logs.pop_front();
                    }
                }
                None => break,
            },
            ev = events.next() => match ev {
                Some(Ok(Event::Key(k))) if is_quit(&k) => break,
                Some(Err(e)) => return Err(e.into()),
                None => break,
                _ => {}
            },
        }
    }

    Ok(())
}

fn draw(f: &mut Frame, logo: &Text<'_>, logs: &VecDeque<String>) {
    let outer = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Min(1), Constraint::Length(1)])
        .split(f.area());

    let cols = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([Constraint::Length(LOGO_WIDTH), Constraint::Min(1)])
        .split(outer[0]);

    let left = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length(LOGO_HEIGHT),
            Constraint::Length(1),
            Constraint::Min(0),
        ])
        .split(cols[0]);

    f.render_widget(Paragraph::new(logo.clone()), left[0]);

    let version = format!("Ferri v{}", env!("CARGO_PKG_VERSION"));
    f.render_widget(
        Paragraph::new(version).alignment(Alignment::Center),
        left[1],
    );

    let visible_rows = cols[1].height as usize;
    let lines: Vec<Line> = logs
        .iter()
        .rev()
        .take(visible_rows)
        .rev()
        .map(|s| Line::from(s.as_str()))
        .collect();

    f.render_widget(Paragraph::new(lines), cols[1]);

    let footer =
        Paragraph::new(" q: quit  ·  Ctrl-C: quit").style(Style::default().fg(Color::DarkGray));
    f.render_widget(footer, outer[1]);
}

fn is_quit(k: &crossterm::event::KeyEvent) -> bool {
    matches!(k.code, KeyCode::Char('q'))
        || (matches!(k.code, KeyCode::Char('c')) && k.modifiers.contains(KeyModifiers::CONTROL))
}

/// RAII helper: restore the terminal even if the run loop panics.
struct TerminalGuard;

impl TerminalGuard {
    fn new() -> anyhow::Result<Self> {
        enable_raw_mode()?;
        execute!(io::stdout(), EnterAlternateScreen)?;
        Ok(Self)
    }
}

impl Drop for TerminalGuard {
    fn drop(&mut self) {
        let _ = disable_raw_mode();
        let _ = execute!(io::stdout(), LeaveAlternateScreen);
    }
}
