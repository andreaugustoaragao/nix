use serde::{Deserialize, Serialize};

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Handoff {
    pub token: String,
    pub page: String,
    pub prompt: String,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct UserRequest {
    pub token: String,
    pub action: UserAction,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case", deny_unknown_fields)]
pub enum UserAction {
    Frame,
    Click {
        document: String,
        origin: String,
        x: f64,
        y: f64,
    },
    Fill {
        document: String,
        origin: String,
        reference: String,
        text: String,
    },
    Press {
        document: String,
        origin: String,
        reference: String,
    },
    Text {
        document: String,
        origin: String,
        text: String,
    },
    Key {
        document: String,
        origin: String,
        key: String,
    },
    Scroll {
        document: String,
        origin: String,
        y: i32,
    },
}

impl UserAction {
    pub fn kind(&self) -> &'static str {
        match self {
            Self::Frame => "assist_frame",
            Self::Click { .. } | Self::Press { .. } => "click",
            Self::Fill { .. } | Self::Text { .. } => "fill",
            Self::Key { .. } => "key",
            Self::Scroll { .. } => "scroll",
        }
    }

    pub fn binding(&self) -> Option<(&str, &str)> {
        match self {
            Self::Frame => None,
            Self::Click {
                document, origin, ..
            }
            | Self::Fill {
                document, origin, ..
            }
            | Self::Press {
                document, origin, ..
            }
            | Self::Text {
                document, origin, ..
            }
            | Self::Key {
                document, origin, ..
            }
            | Self::Scroll {
                document, origin, ..
            } => Some((document, origin)),
        }
    }
}
