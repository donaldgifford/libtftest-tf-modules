package awsapi

import (
	"errors"
	"testing"

	bedrocktypes "github.com/aws/aws-sdk-go-v2/service/bedrock/types"
	runtimetypes "github.com/aws/aws-sdk-go-v2/service/bedrockruntime/types"
)

func TestClassifyPutUseCaseErr(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name string
		in   error
		want error // sentinel to errors.Is against, or nil
		wrap bool  // expect a wrapped (non-sentinel, non-nil) error
	}{
		{name: "nil stays nil", in: nil, want: nil},
		{
			name: "conflict becomes already-exists sentinel",
			in:   &bedrocktypes.ConflictException{},
			want: ErrUseCaseAlreadyExists,
		},
		{
			name: "other error is wrapped",
			in:   errors.New("access denied"),
			wrap: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()

			got := classifyPutUseCaseErr(tt.in)
			switch {
			case tt.wrap:
				if got == nil || errors.Is(got, ErrUseCaseAlreadyExists) {
					t.Errorf("got %v, want a wrapped generic error", got)
				}
			case tt.want == nil:
				if got != nil {
					t.Errorf("got %v, want nil", got)
				}
			default:
				if !errors.Is(got, tt.want) {
					t.Errorf("got %v, want errors.Is %v", got, tt.want)
				}
			}
		})
	}
}

func TestClassifyInvokeErr(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name string
		in   error
		want error
		wrap bool
	}{
		{name: "nil stays nil", in: nil, want: nil},
		{
			name: "conflict becomes already-subscribed",
			in:   &runtimetypes.ConflictException{},
			want: ErrAlreadySubscribed,
		},
		{
			name: "validation becomes input-rejected (access granted)",
			in:   &runtimetypes.ValidationException{},
			want: ErrModelInputRejected,
		},
		{
			name: "other error is wrapped",
			in:   errors.New("throttled"),
			wrap: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()

			got := classifyInvokeErr("anthropic.model", tt.in)
			switch {
			case tt.wrap:
				if got == nil ||
					errors.Is(got, ErrAlreadySubscribed) ||
					errors.Is(got, ErrModelInputRejected) {
					t.Errorf("got %v, want a wrapped generic error", got)
				}
			case tt.want == nil:
				if got != nil {
					t.Errorf("got %v, want nil", got)
				}
			default:
				if !errors.Is(got, tt.want) {
					t.Errorf("got %v, want errors.Is %v", got, tt.want)
				}
			}
		})
	}
}
