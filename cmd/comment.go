package main

import (
	"crypto/sha1"
	"encoding/json"
	"fmt"
	"io"
	"net/http"

	"github.com/xanzy/go-gitlab"
)

type PostCommentRequest struct {
	Comment        string     `json:"comment"`
	FileName       string     `json:"file_name"`
	NewLine        *int       `json:"new_line,omitempty"`
	OldLine        *int       `json:"old_line,omitempty"`
	HeadCommitSHA  string     `json:"head_commit_sha"`
	BaseCommitSHA  string     `json:"base_commit_sha"`
	StartCommitSHA string     `json:"start_commit_sha"`
	Type           string     `json:"type"`
	LineRange      *LineRange `json:"line_range,omitempty"`
}

// LineRange represents the range of a note.
type LineRange struct {
	StartRange *LinePosition `json:"start"`
	EndRange   *LinePosition `json:"end"`
}

// LinePosition represents a position in a line range.
// unlike gitlab struct this does not contain LineCode with sha1 of filename
type LinePosition struct {
	Type    string `json:"type"`
	OldLine int    `json:"old_line"`
	NewLine int    `json:"new_line"`
}

type DeleteCommentRequest struct {
	NoteId       int    `json:"note_id"`
	DiscussionId string `json:"discussion_id"`
}

type EditCommentRequest struct {
	Comment      string `json:"comment"`
	NoteId       int    `json:"note_id"`
	DiscussionId string `json:"discussion_id"`
	Resolved     bool   `json:"resolved"`
}

type CommentResponse struct {
	SuccessResponse
	Comment    *gitlab.Note       `json:"note"`
	Discussion *gitlab.Discussion `json:"discussion"`
}

func (a *api) commentHandler(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodDelete:
		a.DeleteComment(w, r)
	case http.MethodPost:
		a.PostComment(w, r)
	case http.MethodPatch:
		a.EditComment(w, r)
	default:
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Access-Control-Allow-Methods", fmt.Sprintf("%s, %s, %s", http.MethodDelete, http.MethodPost, http.MethodPatch))
		handleError(w, InvalidRequestError{}, "Expected DELETE, POST or PATCH", http.StatusMethodNotAllowed)
	}
}

func (a *api) DeleteComment(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	body, err := io.ReadAll(r.Body)
	if err != nil {
		handleError(w, err, "Could not read request body", http.StatusBadRequest)
		return
	}

	defer r.Body.Close()

	var deleteCommentRequest DeleteCommentRequest
	err = json.Unmarshal(body, &deleteCommentRequest)
	if err != nil {
		handleError(w, err, "Could not read JSON from request", http.StatusBadRequest)
		return
	}

	res, err := a.client.DeleteMergeRequestDiscussionNote(a.projectInfo.ProjectId, a.projectInfo.MergeId, deleteCommentRequest.DiscussionId, deleteCommentRequest.NoteId)

	if err != nil {
		handleError(w, err, "Could not delete comment", http.StatusInternalServerError)
		return
	}

	if res.StatusCode >= 300 {
		handleError(w, GenericError{endpoint: "/comment"}, "Could not delete comment", res.StatusCode)
		return
	}

	w.WriteHeader(http.StatusOK)
	response := SuccessResponse{
		Message: "Comment deleted successfully",
		Status:  http.StatusOK,
	}

	err = json.NewEncoder(w).Encode(response)
	if err != nil {
		handleError(w, err, "Could not encode response", http.StatusInternalServerError)
	}
}

func (a *api) PostComment(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")

	body, err := io.ReadAll(r.Body)
	if err != nil {
		handleError(w, err, "Could not read request body", http.StatusBadRequest)
		return
	}

	defer r.Body.Close()

	var postCommentRequest PostCommentRequest
	err = json.Unmarshal(body, &postCommentRequest)
	if err != nil {
		handleError(w, err, "Could not unmarshal data from request body", http.StatusBadRequest)
		return
	}

	opt := gitlab.CreateMergeRequestDiscussionOptions{
		Body: &postCommentRequest.Comment,
	}

	/* If we are leaving a comment on a line, leave position. Otherwise,
	we are leaving a note (unlinked comment) */
	if postCommentRequest.FileName != "" {
		opt.Position = &gitlab.PositionOptions{
			PositionType: &postCommentRequest.Type,
			StartSHA:     &postCommentRequest.StartCommitSHA,
			HeadSHA:      &postCommentRequest.HeadCommitSHA,
			BaseSHA:      &postCommentRequest.BaseCommitSHA,
			NewPath:      &postCommentRequest.FileName,
			OldPath:      &postCommentRequest.FileName,
			NewLine:      postCommentRequest.NewLine,
			OldLine:      postCommentRequest.OldLine,
		}

		if postCommentRequest.LineRange != nil {
			var format = "%x_%d_%d"
			var start_filename_sha1 = fmt.Sprintf(
				format,
				sha1.Sum([]byte(postCommentRequest.FileName)),
				postCommentRequest.LineRange.StartRange.OldLine,
				postCommentRequest.LineRange.StartRange.NewLine,
			)
			var end_filename_sha1 = fmt.Sprintf(
				format,
				sha1.Sum([]byte(postCommentRequest.FileName)),
				postCommentRequest.LineRange.EndRange.OldLine,
				postCommentRequest.LineRange.EndRange.NewLine,
			)
			opt.Position.LineRange = &gitlab.LineRangeOptions{
				Start: &gitlab.LinePositionOptions{
					Type:     &postCommentRequest.LineRange.StartRange.Type,
					LineCode: &start_filename_sha1,
				},
				End: &gitlab.LinePositionOptions{
					Type:     &postCommentRequest.LineRange.EndRange.Type,
					LineCode: &end_filename_sha1,
				},
			}
		}
	}

	discussion, res, err := a.client.CreateMergeRequestDiscussion(a.projectInfo.ProjectId, a.projectInfo.MergeId, &opt)

	if err != nil {
		handleError(w, err, "Could not create comment", http.StatusBadRequest)
		return
	}

	if res.StatusCode >= 300 {
		handleError(w, GenericError{endpoint: "/comment"}, "Could not create comment", res.StatusCode)
		return
	}

	w.WriteHeader(http.StatusOK)
	response := CommentResponse{
		SuccessResponse: SuccessResponse{
			Message: "Comment created successfully",
			Status:  http.StatusOK,
		},
		Comment:    discussion.Notes[0],
		Discussion: discussion,
	}

	err = json.NewEncoder(w).Encode(response)
	if err != nil {
		handleError(w, err, "Could not encode response", http.StatusInternalServerError)
	}
}

func (a *api) EditComment(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	body, err := io.ReadAll(r.Body)

	if err != nil {
		handleError(w, err, "Could not read request body", http.StatusBadRequest)
		return
	}

	defer r.Body.Close()

	var editCommentRequest EditCommentRequest
	err = json.Unmarshal(body, &editCommentRequest)
	if err != nil {
		handleError(w, err, "Could not unmarshal data from request body", http.StatusBadRequest)
		return
	}

	options := gitlab.UpdateMergeRequestDiscussionNoteOptions{}
	options.Body = gitlab.String(editCommentRequest.Comment)

	note, res, err := a.client.UpdateMergeRequestDiscussionNote(a.projectInfo.ProjectId, a.projectInfo.MergeId, editCommentRequest.DiscussionId, editCommentRequest.NoteId, &options)

	if err != nil {
		handleError(w, err, "Could not update comment", http.StatusInternalServerError)
		return
	}

	if res.StatusCode >= 300 {
		handleError(w, GenericError{endpoint: "/comment"}, "Could not update comment", res.StatusCode)
		return
	}

	w.WriteHeader(http.StatusOK)
	response := CommentResponse{
		SuccessResponse: SuccessResponse{
			Message: "Comment updated successfully",
			Status:  http.StatusOK,
		},
		Comment: note,
	}

	err = json.NewEncoder(w).Encode(response)
	if err != nil {
		handleError(w, err, "Could not encode response", http.StatusInternalServerError)
	}
}
